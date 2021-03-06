// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0 <0.8.0;

interface IWOKT9 {
    function deposit() external payable;

    function transfer(address to, uint value) external returns (bool);

    function withdraw(uint) external;
}
