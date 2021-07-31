// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

interface IJfOracle {
    
    function convert2JF(address _token, uint256 _amount) external returns (uint256 _jfAmount);
}
