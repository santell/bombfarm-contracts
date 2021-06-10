// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;
pragma abicoder v1;

interface IVenusStrategyBNB {
    function want() external view returns (address);
    function deposit() external;
    function withdraw(uint256) external;
    function updateBalance() external;
    function balanceOf() external view returns (uint256);
    function retireStrat() external;
    function harvest() external;
}
