// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";

import "src/bonding-curve/BondingCurve.sol";
import "src/bonding-curve/FFactory.sol";
import "src/bonding-curve/FRouter.sol";
import "src/agent/AgentFactory.sol";

import "src/pool/IUniswapV2Router02.sol";
import "src/pool/IUniswapV2Pair.sol";

import "src/agent/AgentNFT.sol";
import "src/agent/AgentToken.sol";
import "src/agent/AgentVeToken.sol";

import "test/MockYoko.sol";

contract BondingTest is Test {
    BondingCurve public bondingImplementation;
    FFactory public factoryImplementation;
    FRouter public routerImplementation;
    AgentFactory public agentFactoryImplementation;
    MockYoko public yokoToken;

    AgentToken public agentTokenImplementation;
    AgentNFT public agentNFTImplementation;
    AgentVeToken public agentVeTokenImplementation;

    ProxyAdmin public proxyAdmin;

    TransparentUpgradeableProxy public factoryProxy;
    TransparentUpgradeableProxy public routerProxy;
    TransparentUpgradeableProxy public bondingProxy;
    TransparentUpgradeableProxy public agentFactoryProxy;
    TransparentUpgradeableProxy public agentNFTProxy;

    BondingCurve public bondingInstance;
    FFactory public factoryInstance;
    FRouter public routerInstance;
    AgentFactory public agentFactoryInstance;
    AgentNFT public agentNFTInstance;

    // uniswap contracts
    address public univ2Router;

    address public feeReceiver;
    address public taxVault;
    address public creator;

    address public user1;
    address public user2;

    uint256 public startingSupply;
    uint256 public expectedStartingAssetReserve;
    uint256 public k; // constant product

    function setUp() public {
        feeReceiver = vm.addr(10);
        taxVault = vm.addr(11);
        creator = vm.addr(12);
        user1 = vm.addr(1);
        user2 = vm.addr(2);

        startingSupply = 1000000000;

        yokoToken = new MockYoko();

        // deploy contract implementations
        factoryImplementation = new FFactory();
        routerImplementation = new FRouter();
        bondingImplementation = new BondingCurve();
        agentFactoryImplementation = new AgentFactory();
        agentTokenImplementation = new AgentToken();
        agentNFTImplementation = new AgentNFT();
        agentVeTokenImplementation = new AgentVeToken();

        // deploy uniswapv2
        univ2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

        // deploy proxies
        factoryProxy = new TransparentUpgradeableProxy(address(factoryImplementation), address(this), "");
        routerProxy = new TransparentUpgradeableProxy(address(routerImplementation), address(this), "");
        bondingProxy = new TransparentUpgradeableProxy(address(bondingImplementation), address(this), "");
        agentFactoryProxy = new TransparentUpgradeableProxy(address(agentFactoryImplementation), address(this), "");
        agentNFTProxy = new TransparentUpgradeableProxy(address(agentNFTImplementation), address(this), "");

        // set instances
        factoryInstance = FFactory(address(factoryProxy));
        routerInstance = FRouter(address(routerProxy));
        bondingInstance = BondingCurve(address(bondingProxy));
        agentFactoryInstance = AgentFactory(address(agentFactoryProxy));
        agentNFTInstance = AgentNFT(address(agentNFTProxy));

        // initialize
        factoryInstance.initialize(taxVault, address(routerInstance), 1, 1); // 1% tax on buy/sell
        routerInstance.initialize(address(factoryInstance), address(yokoToken));
        bondingInstance.initialize(
            address(factoryInstance),
            address(routerInstance),
            feeReceiver,
            address(agentFactoryInstance),
            100e18,
            startingSupply,
            5000,
            100,
            200000000e18
        );
        agentFactoryInstance.initialize(
            address(agentTokenImplementation),
            address(agentVeTokenImplementation),
            address(yokoToken),
            address(agentNFTInstance),
            2000e18,
            1
        );
        agentNFTInstance.initialize();
        agentFactoryInstance.setTokenAdmin(address(this));
        agentFactoryInstance.setTokenSupplyParams(1000000000, 1000000000, 0, address(0));
        agentFactoryInstance.setTokenTaxParams(100, 100, 1, taxVault);
        agentFactoryInstance.setUniswapRouter(univ2Router);
        agentFactoryInstance.setLockDuration(1 days);

        // assign roles
        factoryInstance.grantRole(factoryInstance.CREATOR_ROLE(), address(bondingInstance));
        routerInstance.grantRole(routerInstance.EXECUTOR_ROLE(), address(bondingInstance));
        agentFactoryInstance.grantRole(agentFactoryInstance.BONDING_ROLE(), address(bondingInstance));
        agentNFTInstance.grantRole(agentNFTImplementation.MINTER_ROLE(), address(agentFactoryInstance));

        // mint creator, user1, and user2 500 yoko tokens
        yokoToken.mint(creator, 500e18);
        yokoToken.mint(user1, 500e18);
        yokoToken.mint(user2, 500e18);
        assertEq(yokoToken.balanceOf(creator), 500e18);
        assertEq(yokoToken.balanceOf(user1), 500e18);
        assertEq(yokoToken.balanceOf(user2), 500e18);

        // set expected asset pool reserve and constant product
        expectedStartingAssetReserve =
            (bondingInstance.K() * 10000 / bondingInstance.assetRate()) * 10000e18 / startingSupply / 10000;
        k = expectedStartingAssetReserve * startingSupply * 1e18;
    }

    function testCreateToken() public returns (address, address) {
        vm.startPrank(creator);
        yokoToken.approve(address(bondingInstance), 100e18);

        // create token with no additional purchase
        (address bondingToken, address pair, uint256 id) = bondingInstance.create("test", "test", 100e18);

        uint256 startingLiquidity = bondingInstance.calculateInitialLiquidity(startingSupply * 1e18);

        // get pair info
        FPair fPair = FPair(pair);
        FPair.Pool memory pool = fPair.getPoolInfo();

        // check mappings
        address[] memory tokens = bondingInstance.getUserTokens(creator);
        assertEq(tokens[0], bondingToken);

        (
            address tokenCreator,
            address _token,
            address _pair,
            address agentToken,
            bool bonding,
            bool trading,
            BondingCurve.Data memory data
        ) = bondingInstance.tokenInfo(bondingToken);

        assertEq(tokenCreator, creator);
        assertEq(_token, bondingToken);
        assertEq(_pair, pair);
        assertEq(agentToken, address(0));
        assertEq(bonding, true);
        assertEq(trading, false);

        assertEq(data.token, bondingToken);
        assertEq(data.tokenName, "yoko fun test");
        assertEq(data._name, "test");
        assertEq(data.ticker, "test");
        assertEq(data.supply, startingSupply * 1e18);
        assertEq(data.price, startingSupply * 1e18 / startingLiquidity);
        assertEq(data.marketCap, startingLiquidity);
        assertEq(data.volume, 0);
        assertEq(data.volume24H, 0);
        assertEq(data.prevPrice, startingSupply * 1e18 / startingLiquidity);
        assertEq(data.lastUpdated, block.timestamp);

        return (bondingToken, pair);
    }

    // function testCreateWithPurchase() public {
    //     vm.startPrank(creator);
    //     yokoToken.approve(address(bondingInstance), 500e18);

    //     // create token with additional purchase of 400 YOKO
    //     (address bondingToken, address pair, uint256 id) = bondingInstance.create("test", "test", 500e18);
    //     uint256 startingLiquidity = bondingInstance.calculateInitialLiquidity(startingSupply * 1e18);
    //     uint256 buyTaxFee = 400e18 * factoryInstance.buyTax() / 100;
    //     uint256 buyAmountAfterFee = 400e18 - buyTaxFee;

    //     // check creator, tax vault, and pool YOKO balance after
    //     assertEq(yokoToken.balanceOf(creator), 0);
    //     assertEq(yokoToken.balanceOf(pair), buyAmountAfterFee);
    //     assertEq(yokoToken.balanceOf(taxVault), buyTaxFee);

    //     // get pair info
    //     FPair fPair = FPair(pair);
    //     FPair.Pool memory pool = fPair.getPoolInfo();

    //     // check mappings
    //     address[] memory tokens = bondingInstance.getUserTokens(creator);
    //     assertEq(tokens[0], bondingToken);

    //     // calculate expected pool reserves and check that creator received bonding tokens
    //     uint256 newReserveB = expectedStartingAssetReserve + buyAmountAfterFee;
    //     uint256 newReserveA = k / newReserveB;
    //     uint256 amountOut = startingSupply * 1e18 - newReserveA;
    //     assertEq(FERC20(bondingToken).balanceOf(creator), amountOut);
    //     assertEq(pool.k, k);
    //     assertEq(pool.reserve0, newReserveA);
    //     assertEq(pool.reserve1, newReserveB);
    // }

    // function testBuy() public returns (address, address) {
    //     // create bonding token
    //     (address bondingToken, address pair) = testCreateToken();

    //     // retrieve current pool reserves
    //     FPair fPair = FPair(pair);
    //     FPair.Pool memory currentPoolInfo = fPair.getPoolInfo();

    //     // user1 buys 300 YOKO worth of bonding tokens
    //     vm.startPrank(user1);
    //     yokoToken.approve(address(routerInstance), 300e18);
    //     bondingInstance.buy(300e18, bondingToken);

    //     uint256 taxAmount = 300e18 * factoryInstance.buyTax() / 100;
    //     uint256 buyAmountAfterTax = 300e18 - taxAmount;

    //     uint256 newReserveB = currentPoolInfo.reserve1 + buyAmountAfterTax;
    //     uint256 newReserveA = k / newReserveB;
    //     uint256 amountOut = currentPoolInfo.reserve0 - newReserveA;

    //     FPair.Pool memory newPoolInfo = fPair.getPoolInfo();
    //     assertEq(newPoolInfo.reserve0, newReserveA);
    //     assertEq(newPoolInfo.reserve1, newReserveB);
    //     assertEq(newPoolInfo.lastUpdated, block.timestamp);

    //     assertEq(yokoToken.balanceOf(user1), 200e18);
    //     assertEq(yokoToken.balanceOf(pair), buyAmountAfterTax);
    //     assertEq(yokoToken.balanceOf(taxVault), taxAmount);
    //     assertEq(FERC20(bondingToken).balanceOf(user1), amountOut);
    //     assertEq(FERC20(bondingToken).balanceOf(pair), currentPoolInfo.reserve0 - amountOut);

    //     // check token data updated
    //     (,,,,,, BondingCurve.Data memory data) = bondingInstance.tokenInfo(bondingToken);

    //     assertEq(data.price, newReserveA / newReserveB);
    //     assertEq(data.marketCap, startingSupply * 1e18 * newReserveB / newReserveA);
    //     assertEq(data.liquidity, newReserveB * 2);
    //     assertEq(data.volume, buyAmountAfterTax);
    //     assertEq(data.volume24H, buyAmountAfterTax);
    //     assertEq(data.prevPrice, currentPoolInfo.reserve0 / currentPoolInfo.reserve1);

    //     return (bondingToken, pair);
    // }

    // function testSell() public {
    //     // create bonding token and purchase tokens
    //     (address bondingToken, address pair) = testBuy();

    //     // retrieve current pool reserves and token data
    //     FPair.Pool memory currentPoolInfo = FPair(pair).getPoolInfo();
    //     (,,,,,, BondingCurve.Data memory currentData) = bondingInstance.tokenInfo(bondingToken);

    //     // retrieve user1 and vault yoko balance before sale
    //     uint256 user1YokoBalanceBeforeSale = yokoToken.balanceOf(user1);
    //     uint256 vaultYokoBalanceBeforeSale = yokoToken.balanceOf(taxVault);
    //     uint256 pairYokoBalanceBeforeSale = yokoToken.balanceOf(pair);

    //     // user1 sells all bonding tokens owned
    //     uint256 sellAmount = FERC20(bondingToken).balanceOf(user1);
    //     vm.startPrank(user1);
    //     FERC20(bondingToken).approve(address(routerInstance), sellAmount);
    //     bondingInstance.sell(sellAmount, bondingToken);

    //     uint256 newReserveA = currentPoolInfo.reserve0 + sellAmount;
    //     uint256 newReserveB = k / newReserveA;
    //     uint256 amountOut = currentPoolInfo.reserve1 - newReserveB;

    //     uint256 taxAmount = amountOut * factoryInstance.sellTax() / 100;

    //     FPair.Pool memory newPoolInfo = FPair(pair).getPoolInfo();
    //     assertEq(newPoolInfo.reserve0, newReserveA);
    //     assertEq(newPoolInfo.reserve1, newReserveB);
    //     assertEq(newPoolInfo.lastUpdated, block.timestamp);

    //     assertEq(yokoToken.balanceOf(user1), user1YokoBalanceBeforeSale + amountOut - taxAmount);
    //     assertEq(yokoToken.balanceOf(pair), pairYokoBalanceBeforeSale - amountOut);
    //     assertEq(yokoToken.balanceOf(taxVault), vaultYokoBalanceBeforeSale + taxAmount);
    //     assertEq(FERC20(bondingToken).balanceOf(user1), 0);
    //     assertEq(FERC20(bondingToken).balanceOf(pair), currentPoolInfo.reserve0 + sellAmount);

    //     // check token data updated
    //     (,,,,,, BondingCurve.Data memory data) = bondingInstance.tokenInfo(bondingToken);

    //     assertEq(data.price, newReserveA / newReserveB);
    //     assertEq(data.marketCap, startingSupply * 1e18 * newReserveB / newReserveA);
    //     assertEq(data.liquidity, newReserveB * 2);
    //     assertEq(data.volume, currentData.volume + amountOut);
    //     assertEq(data.volume24H, currentData.volume24H + amountOut);
    // }

    // test launch
    function testLaunch() public {
        // create token and pair
        (address bondingToken, address pair_) = testCreateToken();

        FPair.Pool memory currentPoolInfo = FPair(pair_).getPoolInfo();

        uint256 reserve1RequiredForLaunch = k / bondingInstance.launchThreshold();
        uint256 additionalAmount1Needed = reserve1RequiredForLaunch - currentPoolInfo.reserve1;
        uint256 purchaseAmount = additionalAmount1Needed * 110 / 100; // additional to cover tax

        vm.startPrank(user1);
        yokoToken.mint(user1, purchaseAmount);
        yokoToken.approve(address(routerInstance), purchaseAmount);

        bondingInstance.buy(purchaseAmount, bondingToken);

        // retrieve newly created agent token
        address agentToken = agentFactoryInstance.allAgentTokens(0);

        // check bonding and trading states
        (,,, address agentToken_, bool bonding, bool trading,) = bondingInstance.tokenInfo(bondingToken);
        assertEq(bonding, false);
        assertEq(trading, true);
        assertEq(agentToken_, agentToken);

        // check that NFT is minted to creator
        assertEq(agentNFTInstance.ownerOf(1), creator);

        // get agentInfo from nft
        AgentNFT.AgentInfo memory agentInfo = agentNFTInstance.getAgentInfo(1);
        assertEq(agentInfo.agentToken, agentToken);
        assertEq(agentInfo.creator, creator);

        // confirm that liquidity was added
        IUniswapV2Pair uniPair = IUniswapV2Pair(agentInfo.lp);
        uint256 lpSupply = uniPair.totalSupply();
        (uint256 reserve0, uint256 reserve1,) = uniPair.getReserves();
        assertNotEq(reserve0, 0);
        assertNotEq(reserve1, 0);
        assertNotEq(lpSupply, 0);

        // confirm that lp was staked (using approxEq because add liq has rounding errors)
        AgentVeToken veToken = AgentVeToken(agentFactoryInstance.allVeTokens(0));
        assertApproxEqAbs(lpSupply, uniPair.balanceOf(address(veToken)), 1e18);
        assertApproxEqAbs(lpSupply, veToken.initialLock(), 1e18);
        assertEq(veToken.unlockAt(), block.timestamp + agentFactoryInstance.lockDuration());
        assertApproxEqAbs(veToken.balanceOf(creator), lpSupply, 1e18);
    }

    // test redemption
    function testRedemption() public {
        // launch agent token
        testLaunch();

        // retrieve bondingToken
        address[] memory tokens = bondingInstance.getUserTokens(creator);
        address bondingToken = tokens[0];
        // retrieve newly created agent token
        address agentToken = agentFactoryInstance.allAgentTokens(0);

        uint256 creatorBondingBalance = FERC20(bondingToken).balanceOf(user1);

        address[] memory a = new address[](1);
        a[0] = user1;

        vm.startPrank(user1);
        AgentNFT.AgentInfo memory agentInfo = agentNFTInstance.getAgentInfo(1);

        FERC20(bondingToken).approve(address(bondingInstance), creatorBondingBalance);
        uint256 approvalAmount =
            AgentToken(payable(agentToken)).allowance(AgentToken(payable(agentToken)).vault(), address(bondingInstance));
        console.log(approvalAmount);
        bondingInstance.redeemBondingTokenForAgentToken(bondingToken, a);

        uint256 newBondingBalance = FERC20(bondingToken).balanceOf(user1);
        uint256 agentTokenBalance = AgentToken(payable(agentToken)).balanceOf(user1);

        assertEq(creatorBondingBalance, agentTokenBalance);
        assertEq(newBondingBalance, 0);

        console.log(creatorBondingBalance);
        console.log(agentTokenBalance);
    }

    // function testRevertBondingContract() public {
    //     // create token and pair
    //     (address token, address pair) = testCreateToken();

    //     vm.startPrank(user1);
    //     vm.expectRevert();
    //     bondingInstance.setInitialSupply(startingSupply * 1e18);

    //     vm.expectRevert();
    //     bondingInstance.setLaunchThreshold(1);

    //     vm.expectRevert();
    //     bondingInstance.setFeeAmount(1);

    //     vm.expectRevert();
    //     bondingInstance.setFeeReceiver(user1);

    //     vm.expectRevert();
    //     bondingInstance.setMaxTxAmount(1);

    //     vm.expectRevert();
    //     bondingInstance.setAssetRate(1);

    //     FERC20 bondingToken = FERC20(token);

    //     vm.expectRevert();
    //     bondingToken.updateMaxTx(1);

    //     vm.expectRevert();
    //     bondingToken.excludeFromMaxTx(user1);

    //     vm.expectRevert();
    //     bondingToken.burnFrom(user2, 1);
    // }

    // function testRevertTokenContract() public {
    //     // create token and pair
    //     (address token, address pair) = testCreateToken();

    //     FERC20 bondingToken = FERC20(token);

    //     vm.expectRevert();
    //     bondingToken.updateMaxTx(1);

    //     vm.expectRevert();
    //     bondingToken.excludeFromMaxTx(user1);

    //     vm.expectRevert();
    //     bondingToken.burnFrom(user2, 1);
    // }

    // function testRevertPairContract() public {
    //     // create token and pair
    //     (address token, address pair_) = testCreateToken();

    //     vm.startPrank(user1);
    //     FPair pair = FPair(pair_);
    //     vm.expectRevert();
    //     pair.mint(1, 1);

    //     vm.expectRevert();
    //     pair.swap(1, 1, 1, 1);

    //     vm.expectRevert();
    //     pair.approval(user1, token, 1);

    //     vm.expectRevert();
    //     pair.transferAsset(user1, 1);

    //     vm.expectRevert();
    //     pair.transferTo(user1, 1);
    // }

    // function testRevertFactoryContract() public {
    //     vm.startPrank(user1);
    //     vm.expectRevert();
    //     factoryInstance.createPair(vm.addr(5), vm.addr(6));

    //     vm.expectRevert();
    //     factoryInstance.setTaxVault(vm.addr(5));

    //     vm.expectRevert();
    //     factoryInstance.setSellTax(1);

    //     vm.expectRevert();
    //     factoryInstance.setBuyTax(1);

    //     vm.expectRevert();
    //     factoryInstance.setRouter(vm.addr(5));
    // }

    // function testRevertRouterContract() public {
    //     vm.startPrank(user1);

    //     vm.expectRevert();
    //     routerInstance.addInitialLiquidity(vm.addr(5), 1, 1);

    //     vm.expectRevert();
    //     routerInstance.sell(1, vm.addr(5), vm.addr(6));

    //     vm.expectRevert();
    //     routerInstance.buy(1, vm.addr(5), vm.addr(6));

    //     vm.expectRevert();
    //     routerInstance.launch(vm.addr(5));

    //     vm.expectRevert();
    //     routerInstance.approval(vm.addr(5), vm.addr(6), vm.addr(7), 1);
    // }
}
