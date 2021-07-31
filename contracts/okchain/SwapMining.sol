// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interface/IJswapFactory.sol";
import "../interface/IJswapPair.sol";
import '../libraries/JswapLibrary.sol';
import "../interface/ISwapMining.sol";
import "../interface/IJfOracle.sol";
import "../interface/IJFToken.sol";


enum RewardMode {
    FEE_AND_IL, // reward fee & Impermanence loss 
    FEE        // reward fee
}

contract SwapMining is ISwapMining, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct PoolInfo {
        address pair;
        bool miningable;
        // No TVL limit
        bool permanent;
        // if permanent == false, require TVL(quoteToken) > minTVL
        address quoteToken;
        uint256 minTVL;
        uint256 rewardVolume;
        uint256 rewardRate; // 100-based
        uint256 token0Volume;
        uint256 token1Volume;
        RewardMode rewardMode; //0: reward fee & Impermanence loss 2: reward fee
        
    }

    struct UserInfo {
        address user;
        // amount withdrawable
        uint256 pending;
        uint256 totalEarn;
    }
    // Toatl Mining Reward
    uint256 public totalReward;
    // router address
    address public router;
    address public factory;
    address public devaddr;
    IJFToken public jfToken;
    IJfOracle public oracle;

    PoolInfo[] public pools;
    // 
    mapping(address => uint256) public pairOfIndex;
    //user => pId => amount
    mapping(address => mapping(uint256 => uint256)) public userPending;
    mapping(address => UserInfo) public userInfo;

    modifier onlyRouter() {
        require(msg.sender == router, "SwapMining: caller is not the router");
        _;
    }

    function initialize(address _factory, address _router,  IJFToken _jfToken, IJfOracle _oracle, address _devaddr) external initializer {
        __Ownable_init();
        factory = _factory;
        router = _router;
        jfToken = _jfToken;
        oracle = _oracle;
        devaddr = _devaddr;
    }

    function add(
        address _pair ,
        uint256 _rewardRate,
        bool _permanent,
        address _quoteToken,
        uint256 _minTvl
        ) 
        onlyOwner
        public 
    {
        require(_pair != address(0), "Address cannot empty");
        require(pairOfIndex[_pair] == 0 && (pools.length == 0 || pools[0].pair != _pair), "Can not add repeated");
        
        pairOfIndex[_pair] = pools.length;
        pools.push(PoolInfo({
            pair : _pair,
            miningable : true,
            permanent : _permanent,
            quoteToken : _quoteToken,
            minTVL : _minTvl,
            rewardVolume: 0,
            rewardRate: _rewardRate,
            token0Volume: 0,
            token1Volume: 0,
            rewardMode: RewardMode.FEE_AND_IL
            }));
    }

    function setMintRate(uint256 _pid,  uint256 _rewardRate)
        onlyOwner
        external 
    {
        PoolInfo storage pool =  pools[_pid];
        pool.rewardRate = _rewardRate;
    }

    function setMintable(
        uint256 _pid, 
        bool _miningable, 
        bool _permanent,
        uint256 _minTvl,
        address _quoteToken
        )
        onlyOwner
        external 
    {

        PoolInfo storage pool =  pools[_pid];
        pool.miningable = _miningable;
        pool.permanent = _permanent;
        
        pool.minTVL = _minTvl;
        pool.quoteToken = _quoteToken;
    }

    function setMintMode(uint256 _pid, uint256 _rewardMode)
        onlyOwner
        external 
    {
        require(_rewardMode < 2, "[0,1] accepte");
        PoolInfo storage pool =  pools[_pid];
        pool.rewardMode = _rewardMode == 0 ? RewardMode.FEE_AND_IL : RewardMode.FEE;
    }

    function setRouter(address newRouter) public onlyOwner {
        require(newRouter != address(0), "SwapMining: new router is the zero address");
        router = newRouter;
    }

    /**
     * @notice withdraw JF
     */
    function withdraw() public {
        UserInfo storage user = userInfo[msg.sender];
        require(user.pending > 0, "No goods");
        uint256 pending = user.pending;
        user.pending = 0;
        // delete userPending[msg.sender];
        uint256 length = pools.length;
        for (uint256 pid = 0; pid < length; pid++) {
           if(userPending[msg.sender][pid] > 0){
                delete userPending[msg.sender][pid];
           }
        }

        jfToken.mint(msg.sender, pending);
    }

    function userPoolPending(address _account,uint256 _pid) public view returns(uint256) {
        return userPending[_account][_pid];
    }

    /**
     * mining swap must call befor swap execution
     */
    function swap(address _sender, address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOut)
      external override onlyRouter returns (bool) {

        address pair = JswapLibrary.pairFor(factory, _tokenIn, _tokenOut);
        if(!miningable(pair)){
            return false;
        }
        uint256 pid = pairOfIndex[pair];
        PoolInfo storage poolInfo  = pools[pid];
        //covertToJF
        uint256 jfAmount;
        {
            if(poolInfo.rewardMode == RewardMode.FEE_AND_IL) {
                uint256 flatAmount = flatAmount(pair, _tokenIn, _amountIn);
                uint256 lossAmount = flatAmount.sub(_amountOut);
                (jfAmount) = oracle.convert2JF(_tokenOut, lossAmount);
            }else {
                (jfAmount) = oracle.convert2JF(_tokenIn, _amountIn.mul(3).div(1000));
            }
            // reset amount by scale
            if(poolInfo.rewardRate != 100) {
                jfAmount = jfAmount.mul(poolInfo.rewardRate).div(100);
            }
        }
        // recoding user amount, instead of  transfer to user
        UserInfo storage user = userInfo[_sender];
        user.pending = user.pending.add(jfAmount);
        user.totalEarn = user.totalEarn.add(jfAmount);
        userPending[_sender][pid] = userPending[_sender][pid].add(jfAmount);
        
        if(IJswapPair(pair).token0() == _tokenOut) {
            poolInfo.token0Volume += _amountOut;
        }else {
            poolInfo.token1Volume += _amountOut;
        }

        jfToken.mint(devaddr, jfAmount.div(10));
        //updatePool
        poolInfo.rewardVolume = poolInfo.rewardVolume.add(jfAmount);
        //total
        totalReward = totalReward.add(jfAmount);
    }

    function miningable(address _pair) public view returns (bool){
        
        if(pools.length == 0) {
            return false;
        }

        PoolInfo storage pool = pools[pairOfIndex[_pair] ];

        if(pool.pair == _pair && pool.miningable){
            if(pool.permanent){
                return true;
            }else { // validate TVL
                return getPairTVL(_pair, pool.quoteToken) >= pool.minTVL;
            }
        }
        return false;
    }
    

    function getPairTVL(address _pair, address _quoteToken) public view returns(uint256) {
        (uint256 reserve, uint256 reserve1,) = IJswapPair(_pair).getReserves();
        address token0 = IJswapPair(_pair).token0();
        if(token0 != _quoteToken) {
            reserve = reserve1;
        }
        return reserve;
    }

    function flatAmount(address _pair, address _tokenIn, uint256 _amountIn) public view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut,) = IJswapPair(_pair).getReserves();
        address token0 = IJswapPair(_pair).token0();
        
        if(token0 != _tokenIn) {
            (reserveIn, reserveOut) = (reserveOut, reserveIn);
        }
        return _amountIn.mul(reserveOut).div(reserveIn);
    }
    function pending(address _user ) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        return user.pending;
    }

    function poolLength() public view returns (uint256) {
        return pools.length;
    }
    function poolInfo(uint256 _pid) public view
        returns (
            address pair,
            address quoteToken,
            bool mining,
            bool permanent,
            uint256 rewardVolume,
            uint256 rewardRate,
            uint256 rewardMode,
            uint256 minTVL,
            uint256 token0Volume,
            uint256 token1Volume
            )
     {
        PoolInfo storage pool = pools[_pid];

        return (
            pool.pair,
            pool.quoteToken,
            miningable(pool.pair),
            pool.permanent,
            pool.rewardVolume,
            pool.rewardRate,
            pool.rewardMode == RewardMode.FEE_AND_IL? 0:1,
            pool.minTVL,
            pool.token0Volume,
            pool.token1Volume
            );
    }

    function dev(address _dev ) public onlyOwner {
    //    require(msg.sender == devaddr, "Dev require");
       devaddr = _dev; 
    }
}