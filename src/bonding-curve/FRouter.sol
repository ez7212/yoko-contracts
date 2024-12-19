// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

import "./FFactory.sol";
import "./IFPair.sol";

contract FRouter is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    FFactory public factory;
    address public assetToken;

    error ZeroAddressUnallowed();
    error InvalidAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address assetToken_) external initializer {
        if (factory_ == address(0) || assetToken_ == address(0)) revert ZeroAddressUnallowed();
        __ReentrancyGuard_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        factory = FFactory(factory_);
        assetToken = assetToken_;
    }

    function getAmountsOut(address token, address assetToken_, uint256 amountIn)
        public
        view
        returns (uint256 _amountOut)
    {
        if (token == address(0)) revert ZeroAddressUnallowed();

        address pairAddress = factory.getPair(token, assetToken);

        IFPair pair = IFPair(pairAddress);

        (uint256 reserveA, uint256 reserveB) = pair.getReserves();

        uint256 k = pair.kLast();

        uint256 amountOut;

        if (assetToken_ == assetToken) {
            uint256 newReserveB = reserveB + amountIn;

            uint256 newReserveA = k / newReserveB;

            amountOut = reserveA - newReserveA;
        } else {
            uint256 newReserveA = reserveA + amountIn;

            uint256 newReserveB = k / newReserveA;

            amountOut = reserveB - newReserveB;
        }

        return amountOut;
    }

    function addInitialLiquidity(address token_, uint256 amountToken_, uint256 amountAsset_)
        public
        onlyRole(EXECUTOR_ROLE)
        returns (uint256, uint256)
    {
        if (token_ == address(0)) revert ZeroAddressUnallowed();

        address pairAddress = factory.getPair(token_, assetToken);

        IFPair pair = IFPair(pairAddress);

        IERC20 token = IERC20(token_);

        token.safeTransferFrom(msg.sender, pairAddress, amountToken_);

        pair.mint(amountToken_, amountAsset_);

        return (amountToken_, amountAsset_);
    }

    function sell(uint256 amountIn, address tokenAddress, address to)
        public
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
        returns (uint256, uint256)
    {
        if (tokenAddress == address(0) || to == address(0)) revert ZeroAddressUnallowed();

        address pairAddress = factory.getPair(tokenAddress, assetToken);

        IFPair pair = IFPair(pairAddress);

        IERC20 token = IERC20(tokenAddress);

        uint256 amountOut = getAmountsOut(tokenAddress, address(0), amountIn);

        token.safeTransferFrom(to, pairAddress, amountIn);

        uint256 fee = factory.sellTax();
        uint256 txFee = (fee * amountOut) / 100;

        uint256 amount = amountOut - txFee;
        address feeTo = factory.taxVault();

        pair.transferAsset(to, amount);
        pair.transferAsset(feeTo, txFee);

        pair.swap(amountIn, 0, 0, amountOut);

        return (amountIn, amountOut);
    }

    function buy(uint256 amountIn, address tokenAddress, address to)
        public
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
        returns (uint256, uint256)
    {
        if (tokenAddress == address(0) || to == address(0)) revert ZeroAddressUnallowed();
        if (amountIn == 0) revert InvalidAmount();

        address pair = factory.getPair(tokenAddress, assetToken);

        uint256 fee = factory.buyTax();
        uint256 txFee = (fee * amountIn) / 100;
        address feeTo = factory.taxVault();

        uint256 amount = amountIn - txFee;

        IERC20(assetToken).safeTransferFrom(to, pair, amount);

        IERC20(assetToken).safeTransferFrom(to, feeTo, txFee);

        uint256 amountOut = getAmountsOut(tokenAddress, assetToken, amount);

        IFPair(pair).transferTo(to, amountOut);

        IFPair(pair).swap(0, amountOut, amount, 0);

        return (amount, amountOut);
    }

    function launch(address tokenAddress) public onlyRole(EXECUTOR_ROLE) nonReentrant {
        if (tokenAddress == address(0)) revert ZeroAddressUnallowed();
        address pair = factory.getPair(tokenAddress, assetToken);
        uint256 assetBalance = IFPair(pair).assetBalance();
        FPair(pair).transferAsset(msg.sender, assetBalance);
    }

    function approval(address pair, address asset, address spender, uint256 amount)
        public
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        if (spender == address(0)) revert ZeroAddressUnallowed();

        IFPair(pair).approval(spender, asset, amount);
    }
}