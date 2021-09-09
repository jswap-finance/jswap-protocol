// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;

interface ISingleSmartChef {

    // View returns PoolInfo{ lpToken, allocPoint, lastRewardBlock, accChePerShare }
    function poolInfo(uint256 _pid) external view returns ( address , uint256, uint256, uint256);

    // View returns UserInfo{  amount, rewardDebt }
    function userInfo(address _user) external view returns ( uint256, uint256);
    
    // View function to see pending Reward on frontend.
    function pendingReward(address _user) external view returns (uint256);

    // Stake SYRUP tokens to SmartChef, will take EarnToken 
    function deposit(uint256 _amount) external;

    // Withdraw SYRUP tokens from STAKING, will take EarnToken 
    function withdraw(uint256 _amount) external ;

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() external;

}
