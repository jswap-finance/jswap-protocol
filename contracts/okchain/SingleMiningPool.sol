// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import '../interface/IWETH.sol';
import "../JFToken.sol";


interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to JfSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // JfSwap must mint EXACTLY the same amount of JfSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of Jf. He can make Jf and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once JF is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract SingleMiningPool is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 pending;    // Withdrawable pending JF
        //
        // We do some fancy math here. Basically, any point in time, the amount of JFs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accJfPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accJfPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. JFs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that JFs distribution occurs.
        uint256 accJfPerShare; // Accumulated JFs per share, times 1e12. See below.
    }

    // The JF TOKEN!
    JFToken public jf;
    // Dev address.
    address public devaddr;
    // Block number when bonus JF period ends.
    uint256 public bonusEndBlock;
    // JF tokens created per block.
    uint256 public jfPerBlock;
    // Bonus muliplier for early jf makers.
    uint256 public constant BONUS_MULTIPLIER = 10;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Record lp index in pool  1-based
    mapping (address => uint256) public poolIndex;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when JF mining starts.
    uint256 public startBlock;

    event ClaimAll(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event PerBlockSetting(uint256 _oldValue, uint256 _newValue);

    address constant WETH = 0x8F8526dbfd6E38E3D8307702cA8469Bae6C56C15;
    // address public constant WETH = 0x70c1c53E991F31981d592C2d865383AC0d212225; // testnet
    // address public constant WETH = 0x5FbDB2315678afecb367f032d93F642f64180aa3; // testnet
    

    function initialize(
        JFToken _jf,
        address _devaddr,
        uint256 _jfPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) 
        public 
        initializer
    {
        __Ownable_init();
        jf = _jf;
        devaddr = _devaddr;
        jfPerBlock = _jfPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        require( poolIndex[address(_lpToken)] == 0 , "Can not add repeated");

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accJfPerShare: 0
        }));
        poolIndex[address(_lpToken)] =  poolInfo.length;
    }

    // Update the given pool's JF allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }


    function setJfPerBlock(uint256 _perBlock) external onlyOwner {
        emit PerBlockSetting(jfPerBlock, _perBlock);
        jfPerBlock = _perBlock;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    // View function to see pending JFs on frontend.
    function pendingJf(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accJfPerShare = pool.accJfPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 jfReward = multiplier.mul(jfPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accJfPerShare = accJfPerShare.add(jfReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accJfPerShare).div(1e12).sub(user.rewardDebt);
    }

    function claim(uint256 _pid) external {

        uint256 claimAmount = _claimJf( _pid, msg.sender);
        safeJfTransfer(msg.sender, claimAmount);

        emit Claim(msg.sender, _pid, claimAmount);
    }

    function claimAll() external {

        address account = msg.sender;
        uint256 claimAmount;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            claimAmount += _claimJf( pid, account);
        }
        safeJfTransfer(msg.sender, claimAmount);

        emit ClaimAll(msg.sender, claimAmount);
    }

    function _claimJf(uint256 _pid, address _account) private returns (uint256 _jfAmount){
        UserInfo storage user = userInfo[_pid][_account];
        // if(user.amount > 0) {
            updatePool(_pid);
            PoolInfo storage pool = poolInfo[_pid];
            uint256 pending = user.amount.mul(pool.accJfPerShare).div(1e12).sub(user.rewardDebt);
            // Withdrawable Amount
            _jfAmount = pending + user.pending;
            user.pending = 0;
            user.rewardDebt = user.amount.mul(pool.accJfPerShare).div(1e12);
        // }
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = (address(pool.lpToken) == WETH)? address(this).balance : pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 jfReward = multiplier.mul(jfPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        jf.mint(devaddr, jfReward.div(10));
        jf.mint(address(this), jfReward);
        pool.accJfPerShare = pool.accJfPerShare.add(jfReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit tokens to MasterChef for JF allocation.
    function deposit(uint256 _pid, uint256 _amount) public payable {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accJfPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                user.pending += pending;
                // safeJfTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            if(address(pool.lpToken) == WETH) {
                require(_amount == msg.value, "Msg.value not equal _amount");
                // IWETH(WETH).deposit{value: msg.value}();
            }else {
                require(msg.value == 0, "Msg.value will be zero");
                safeTransferFrom(address(pool.lpToken), address(msg.sender), address(this), _amount );
            }
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accJfPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accJfPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            user.pending += pending;
            // safeJfTransfer(msg.sender, pending);
        }
        
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            user.rewardDebt = user.amount.mul(pool.accJfPerShare).div(1e12);
            if(address(pool.lpToken) == WETH) {
                // IWETH(WETH).withdraw(_amount);
                safeTransferETH(address(msg.sender), _amount);
            } else {
                safeTransfer( address(pool.lpToken), address(msg.sender), _amount);
            }
        } else {
            user.rewardDebt = user.amount.mul(pool.accJfPerShare).div(1e12);
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        safeTransfer( address(pool.lpToken), address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe jf transfer function, just in case if rounding error causes pool to not have enough JFs.
    function safeJfTransfer(address _to, uint256 _amount) internal {
        uint256 jfBal = jf.balanceOf(address(this));
        if (_amount > jfBal) {
            jf.transfer(_to, jfBal);
        } else {
            jf.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public onlyOwner {
        // require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'MasterTransfer: TRANSFER_FROM_FAILED');
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'MasterTransfer: ETH_TRANSFER_FAILED');
    }

    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'MasterTransfer: TRANSFER_FAILED');
    }

    receive() external payable {
        require(msg.sender == WETH, "only accept from WETH"); // only accept ETH via fallback from the WETH contract
    }
}
