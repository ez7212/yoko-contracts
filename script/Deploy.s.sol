// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
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

contract Deploy is Script {
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

    // uniswap contract
    address public univ2Router;

    address public feeReceiver;

    address public taxVault;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("Deploying with address:", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        feeReceiver = 0xD6719344e9c3cAD439E5e4e24C510B22bC50b7B2;
        taxVault = 0x85d342D4B578C59Fb6E26612ea4d372e9d3a3DE8;
        univ2Router = 0xc1F4E7D32269eDeA613E93282142a1397D5DC9c8;
        uint256 startingSupply = 1_000_000_000;

        // deploy yoko and mint deployer 100,000
        yokoToken = new MockYoko();
        yokoToken.mint(deployerAddress, 100000e18);

        // deploy contract implementations
        factoryImplementation = new FFactory();
        routerImplementation = new FRouter();
        bondingImplementation = new BondingCurve();
        agentFactoryImplementation = new AgentFactory();
        agentTokenImplementation = new AgentToken();
        agentNFTImplementation = new AgentNFT();
        agentVeTokenImplementation = new AgentVeToken();

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

        //initialize
        factoryInstance.initialize(taxVault, address(routerInstance), 1, 1); // 1% tax on buys/sells
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
            10000e18,
            1
        );
        agentNFTInstance.initialize();
        agentFactoryInstance.setTokenAdmin(deployerAddress);
        agentFactoryInstance.setTokenSupplyParams(1000000000, 1000000000, 0, address(0));
        agentFactoryInstance.setTokenTaxParams(100, 100, 1, taxVault);
        agentFactoryInstance.setUniswapRouter(univ2Router);
        agentFactoryInstance.setLockDuration(1 days);

        // assign roles
        factoryInstance.grantRole(factoryInstance.CREATOR_ROLE(), address(bondingInstance));
        routerInstance.grantRole(routerInstance.EXECUTOR_ROLE(), address(bondingInstance));
        agentFactoryInstance.grantRole(agentFactoryInstance.BONDING_ROLE(), address(bondingInstance));
        agentNFTInstance.grantRole(agentNFTImplementation.MINTER_ROLE(), address(agentFactoryInstance));

        vm.stopBroadcast();

        console.log("Agent Factory instance deployed to:", address(agentFactoryInstance));
        console.log("Agent NFT instance deployed to:", address(agentNFTInstance));
        console.log("Bonding curve instance deployed to:", address(bondingInstance));
        console.log("Bonding factory instance deployed to:", address(factoryInstance));
        console.log("Bonding router instance deployed to:", address(routerInstance));
        console.log("Yoko token deployed to:", address(yokoToken));
    }
}
