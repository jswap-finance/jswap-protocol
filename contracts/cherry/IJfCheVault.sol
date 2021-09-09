pragma solidity 0.6.12;


interface IJfCheVault {
    function che2Jf(uint256 cheAmount) external view returns (uint256 jfAmount);
    
    function swapCHE2JF(uint256 _cheAmount, address _to ) external returns (uint256 jfAmount);
}