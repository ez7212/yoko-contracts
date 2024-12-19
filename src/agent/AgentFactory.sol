// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";

import "openzeppelin-contracts/contracts/proxy/Clones.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";

import "./IAgentFactory.sol";
import "./IAgentToken.sol";
import "./IAgentVeToken.sol";
import "./IAgentNFT.sol";

contract AgentFactory is IAgentFactory, Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private _nextId;

    address public tokenImplementation;
    address public veTokenImplementation;
    address public nft;
    uint256 public applicationThreshold;
    uint256 public lockDuration;

    address public assetToken; // base currency

    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE"); // Able to withdraw and execute applications

    bytes32 public constant BONDING_ROLE = keccak256("BONDING_ROLE");

    event NewAgent(uint256 id, address token, address lp);

    event NewApplication(uint256 id);

    enum ApplicationStatus {
        Active,
        Executed,
        Withdrawn
    }

    struct Application {
        string name;
        string symbol;
        string tokenURI;
        ApplicationStatus status;
        uint256 withdrawableAmount;
        address proposer;
        uint256 agentId;
    }

    mapping(uint256 => Application) private _applications;

    event ApplicationThresholdUpdated(uint256 newThreshold);
    event LockDurationUpdated(uint256 newLockDuration);
    event TokenImplementationUpdated(address token);

    error ZeroAddressUnallowed();
    error InvalidAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error Unauthorized();
    error ApplicationInactive();
    error TokenAdminNotSet();

    bool internal locked;

    modifier noReentrant() {
        require(!locked, "cannot reenter");
        locked = true;
        _;
        locked = false;
    }

    address[] public allAgentTokens;
    address[] public allVeTokens;
    address private _uniswapRouter;
    address private _tokenAdmin;

    bytes private _tokenSupplyParams;
    bytes private _tokenTaxParams;

    function initialize(
        address tokenImplementation_,
        address veTokenImplementation_,
        address assetToken_,
        address nft_,
        uint256 applicationThreshold_,
        uint256 nextId_
    ) public initializer {
        __Pausable_init();

        if (tokenImplementation_ == address(0) || assetToken_ == address(0) || nft_ == address(0)) {
            revert ZeroAddressUnallowed();
        }

        tokenImplementation = tokenImplementation_;
        veTokenImplementation = veTokenImplementation_;
        assetToken = assetToken_;
        nft = nft_;
        applicationThreshold = applicationThreshold_;
        _nextId = nextId_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function getApplication(uint256 proposalId) public view returns (Application memory) {
        return _applications[proposalId];
    }

    function proposeAgent(string memory name, string memory symbol, string memory tokenURI)
        public
        whenNotPaused
        returns (uint256)
    {
        address sender = _msgSender();
        if (IERC20(assetToken).balanceOf(sender) < applicationThreshold) revert InsufficientBalance();
        if (IERC20(assetToken).allowance(sender, address(this)) < applicationThreshold) revert InsufficientAllowance();

        IERC20(assetToken).safeTransferFrom(sender, address(this), applicationThreshold);

        uint256 id = _nextId++;
        Application memory application =
            Application(name, symbol, tokenURI, ApplicationStatus.Active, applicationThreshold, sender, 0);
        _applications[id] = application;
        emit NewApplication(id);

        return id;
    }

    function withdraw(uint256 id) public noReentrant {
        Application storage application = _applications[id];

        if (msg.sender != application.proposer || hasRole(WITHDRAW_ROLE, msg.sender)) revert Unauthorized();

        if (application.status != ApplicationStatus.Active) revert ApplicationInactive();

        uint256 withdrawableAmount = application.withdrawableAmount;

        application.withdrawableAmount = 0;
        application.status = ApplicationStatus.Withdrawn;

        IERC20(assetToken).safeTransfer(application.proposer, withdrawableAmount);
    }

    function _executeApplication(uint256 id, bytes memory tokenSupplyParams_, bool canStake) internal {
        if (_applications[id].status != ApplicationStatus.Active) revert ApplicationInactive();

        if (_tokenAdmin == address(0)) revert TokenAdminNotSet();

        Application storage application = _applications[id];

        uint256 initialAmount = application.withdrawableAmount;
        application.withdrawableAmount = 0;
        application.status = ApplicationStatus.Executed;

        // create agent token
        address token = _createNewAgentToken(application.name, application.symbol, tokenSupplyParams_);

        // add lp
        address lp = IAgentToken(token).liquidityPools()[0];
        IERC20(assetToken).safeTransfer(token, initialAmount);
        IAgentToken(token).addInitialLiquidity(address(this));

        // mint agent nft
        uint256 _agentId = IAgentNFT(nft).nextAgentId();
        IAgentNFT(nft).mint(application.proposer, token, lp); // mint to creator
        application.agentId = _agentId;

        // lock LP
        address veToken = _createNewAgentVeToken(
            string.concat("Staked ", application.name),
            string.concat("s", application.symbol),
            lp,
            application.proposer,
            canStake
        );

        IERC20(lp).approve(veToken, type(uint256).max);
        IAgentVeToken(veToken).stake(IERC20(lp).balanceOf(address(this)), application.proposer);

        emit NewAgent(_agentId, token, lp);
    }

    function executeApplication(uint256 id, bool canStake) public noReentrant {
        Application storage application = _applications[id];

        if (msg.sender != application.proposer || hasRole(WITHDRAW_ROLE, msg.sender)) revert Unauthorized();

        _executeApplication(id, _tokenSupplyParams, canStake);
    }

    function _createNewAgentToken(string memory name, string memory symbol, bytes memory tokenSupplyParams_)
        internal
        returns (address instance)
    {
        instance = Clones.clone(tokenImplementation);
        IAgentToken(instance).initialize(
            [_tokenAdmin, _uniswapRouter, assetToken], abi.encode(name, symbol), tokenSupplyParams_, _tokenTaxParams
        );

        allAgentTokens.push(instance);
        return instance;
    }

    function _createNewAgentVeToken(
        string memory name,
        string memory symbol,
        address stakingAsset,
        address founder,
        bool canStake
    ) internal returns (address instance) {
        instance = Clones.clone(veTokenImplementation);
        IAgentVeToken(instance).initialize(
            name, symbol, founder, stakingAsset, block.timestamp + lockDuration, address(nft), canStake
        );

        allVeTokens.push(instance);
        return instance;
    }

    function totalAgents() public view returns (uint256) {
        return allAgentTokens.length;
    }

    function setApplicationThreshold(uint256 newThreshold) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold == 0) revert InvalidAmount();
        applicationThreshold = newThreshold;
        emit ApplicationThresholdUpdated(newThreshold);
    }

    function setLockDuration(uint256 newLockDuration) public onlyRole(DEFAULT_ADMIN_ROLE) {
        lockDuration = newLockDuration;
        emit LockDurationUpdated(newLockDuration);
    }

    function setImplementation(address token) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddressUnallowed();
        tokenImplementation = token;
        emit TokenImplementationUpdated(token);
    }

    function setUniswapRouter(address router) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddressUnallowed();
        _uniswapRouter = router;
    }

    function setTokenAdmin(address newTokenAdmin) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTokenAdmin == address(0)) revert ZeroAddressUnallowed();
        _tokenAdmin = newTokenAdmin;
    }

    function setTokenSupplyParams(uint256 maxSupply, uint256 lpSupply, uint256 vaultSupply, address vault)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _tokenSupplyParams = abi.encode(maxSupply, lpSupply, vaultSupply, vault);
    }

    function setTokenTaxParams(
        uint256 projectBuyTaxBasisPoints,
        uint256 projectSellTaxBasisPoints,
        uint256 taxSwapThresholdBasisPoints,
        address projectTaxRecipient
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _tokenTaxParams = abi.encode(
            projectBuyTaxBasisPoints, projectSellTaxBasisPoints, taxSwapThresholdBasisPoints, projectTaxRecipient
        );
    }

    function setAssetToken(address newToken) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newToken == address(0)) revert ZeroAddressUnallowed();
        assetToken = newToken;
    }

    function pause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function initFromBondingCurve(
        string memory name,
        string memory symbol,
        address creator,
        uint256 applicationThreshold_
    ) public whenNotPaused onlyRole(BONDING_ROLE) returns (uint256) {
        address sender = _msgSender();
        require(IERC20(assetToken).balanceOf(sender) >= applicationThreshold_, "Insufficient asset token");
        require(
            IERC20(assetToken).allowance(sender, address(this)) >= applicationThreshold_,
            "Insufficient asset token allowance"
        );

        IERC20(assetToken).safeTransferFrom(sender, address(this), applicationThreshold_);

        uint256 id = _nextId++;
        Application memory application =
            Application(name, symbol, "", ApplicationStatus.Active, applicationThreshold_, creator, id);
        _applications[id] = application;
        emit NewApplication(id);

        return id;
    }

    function executeBondingCurveApplication(uint256 id, uint256 totalSupply, uint256 lpSupply, address vault)
        public
        onlyRole(BONDING_ROLE)
        noReentrant
        returns (address)
    {
        bytes memory tokenSupplyParams = abi.encode(totalSupply, lpSupply, totalSupply - lpSupply, vault);

        _executeApplication(id, tokenSupplyParams, true);

        Application memory application = _applications[id];

        return IAgentNFT(nft).getAgentInfo(application.agentId).agentToken;
    }
}
