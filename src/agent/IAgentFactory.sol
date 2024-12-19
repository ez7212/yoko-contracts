// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAgentFactory {
    function proposeAgent(string memory name, string memory symbol, string memory tokenURI)
        external
        returns (uint256);

    function withdraw(uint256 id) external;

    function totalAgents() external view returns (uint256);

    function initFromBondingCurve(
        string memory name,
        string memory symbol,
        address creator,
        uint256 applicationThreshold_
    ) external returns (uint256);

    function executeBondingCurveApplication(uint256 id, uint256 totalSupply, uint256 lpSupply, address vault)
        external
        returns (address);
}
