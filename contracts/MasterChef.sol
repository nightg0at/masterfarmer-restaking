pragma solidity ^0.6.12;

import './libraries/IERC20.sol';
import './libraries/SafeMath.sol';
import './libraries/SafeERC20.sol';
import './libraries/IERC20.sol';
import './libraries/IUniswapV2Router02.sol';
import './libraries/UniStakingInterfaces.sol';
import './libraries/IUniswapV2Pair.sol';
import './CropsToken.sol';

import "./libraries/restaking/IStakingAdapter.sol"; // nightg0at

interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to CropsSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // CropsSwap must mint EXACTLY the same amount of CropsSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of Crops. He can make Crops and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CROPS is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 otherRewardDebt; // nightg0at
        //
        // We do some fancy math here. Basically, any point in time, the amount of CROPSs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCropsPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCropsPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CROPSs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CROPSs distribution occurs.
        uint256 accCropsPerShare; // Accumulated CROPSs per share, times 1e12. See below.
        // nightg0at
        uint256 accOtherPerShare; // Accumulated OTHERs per share, times 1e12. See below.
        IStakingAdapter adapter; // Manages external farming
        IERC20 otherToken; // The OTHER reward token for this pool, if any
    }

    // The CROPS TOKEN!
    CropsToken public crops;
    // Dev address.
    address public devaddr;
    // Block number when bonus CROPS period ends.
    uint256 public bonusEndBlock;
    // CROPS tokens created per block.
    uint256 public cropsPerBlock = 5*10**18;
    // Bonus muliplier for early crops makers.
    uint256 public constant BONUS_MULTIPLIER = 10;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CROPS mining starts.
    uint256 public startBlock;
    
    // initial value of teamrewards
    uint256 public teamRewardsrate = 300;// 10%
    
    // Max value of tokenperblock
    uint256 public constant maxtokenperblock = 10*10**18;// 1 token
    // Max value of teamrewards
    uint256 public constant maxteamRewardsrate = 1000;// 10%
    
    // The WETH Token
    IERC20 internal weth;
    // The Uniswap v2 Router
    IUniswapV2Router02 internal uniswapRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    // The address of the CROPS-ETH Uniswap pool
    address public cropsPoolAddress;
    
    // Timer variables for globalDecay
    uint256 public timestart = 0;
    uint256 public timeend = now;
    
    // nightg0at
    // Don't add the same pool twice
    mapping (address => bool) private poolIsAdded;

    // Event logs 
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event CropsBuyback(address indexed user, uint256 ethSpentOnCROPS, uint256 cropsBought);

    constructor(
        CropsToken _crops,
        address _devaddr,
        uint256 _cropsPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        crops = _crops;
        devaddr = _devaddr;
        cropsPerBlock = _cropsPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
        
        weth = IERC20(uniswapRouter.WETH());
        
        // Calculate the address the SURF-ETH Uniswap pool will exist at
        address uniswapfactoryAddress = uniswapRouter.factory();
        address cropsAddress = address(crops);
        address wethAddress = address(weth);
        
        // token0 must be strictly less than token1 by sort order to determine the correct address
        (address token0, address token1) = cropsAddress < wethAddress ? (cropsAddress, wethAddress) : (wethAddress, cropsAddress);
        
        cropsPoolAddress = address(uint(keccak256(abi.encodePacked(
            hex'ff',
            uniswapfactoryAddress,
            keccak256(abi.encodePacked(token0, token1)),
            hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f'
        ))));

    }
    
    
    receive() external payable {}
    
    // Internal function that buys back CROPS with the amount of ETH specified
    //function _buyCrops(uint256 _amount) internal returns (uint256 cropsBought) {
    function _buyCrops(uint256 _amount) public returns (uint256 cropsBought) {
        uint256 ethBalance = address(this).balance;
        if (_amount > ethBalance) _amount = ethBalance;
        if (_amount > 0) {
            uint256 deadline = block.timestamp + 5 minutes;
            address[] memory cropsPath = new address[](2);
            cropsPath[0] = address(weth);
            cropsPath[1] = address(crops);
            uint256[] memory amounts = uniswapRouter.swapExactETHForTokens{value: _amount}(0, cropsPath, address(this), deadline);
            cropsBought = amounts[1];
        }
        if (cropsBought > 0) emit CropsBuyback(msg.sender, _amount, cropsBought);
    }
    
    //
    function _addLP(IERC20 _token, IERC20 _pool, uint256 _tokens, uint256 _eth) internal returns (uint256 liquidityAdded) {
        require(_tokens > 0 && _eth > 0);

        IUniswapV2Pair _pair = IUniswapV2Pair(address(_pool));
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();
        bool _isToken0 = _pair.token0() == address(_token);
        uint256 _tokensPerETH = 1e18 * (_isToken0 ? _reserve0 : _reserve1) / (_isToken0 ? _reserve1 : _reserve0);

        _token.safeApprove(address(uniswapRouter), 0);
        if (_tokensPerETH > 1e18 * _tokens / _eth) {
            uint256 _ethValue = 1e18 * _tokens / _tokensPerETH;
            _token.safeApprove(address(uniswapRouter), _tokens);
            ( , , liquidityAdded) = uniswapRouter.addLiquidityETH{value: _ethValue}(address(_token), _tokens, 0, 0, address(this), block.timestamp + 5 minutes);
        } else {
            uint256 _tokenValue = 1e18 * _tokensPerETH / _eth;
            _token.safeApprove(address(uniswapRouter), _tokenValue);
            ( , , liquidityAdded) = uniswapRouter.addLiquidityETH{value: _eth}(address(_token), _tokenValue, 0, 0, address(this), block.timestamp + 5 minutes);
        }
        
    }
    
    //
    function _convertToLP(IERC20 _token, IERC20 _pool, uint256 _amount) internal returns (uint256) {
        require(_amount > 0);

        address[] memory _poolPath = new address[](2);
        _poolPath[0] =  uniswapRouter.WETH();
        _poolPath[1] = address(_token);
        uniswapRouter.swapExactETHForTokens{value: _amount / 2}(0, _poolPath, address(this), block.timestamp + 5 minutes);

        return _addLP(_token, _pool, _token.balanceOf(address(this)), address(this).balance);
    }
    
    
    //
    function depositInto(uint256 _pid) external payable {
        require(msg.value > 0);
        
        IERC20 _pool = poolInfo[_pid].lpToken;
        
        uint256 lpReceived = _convertToLP(crops, _pool, msg.value);
        _pool.safeApprove(address(this), 0);
        _pool.safeApprove(address(this), lpReceived);
        //deposit(_pid, lpReceived);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accCropsPerShare).div(1e12).sub(user.rewardDebt);
            safeCropsTransfer(msg.sender, pending);
        }
        //pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(lpReceived);
        user.rewardDebt = user.amount.mul(pool.accCropsPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, lpReceived);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // nightg0at
    // rudimentary checks for the staking adapter
    modifier validAdapter(IStakingAdapter _adapter) {
        require(address(_adapter) != address(0), "no adapter specified");
        require(_adapter.rewardTokenAddress() != address(0), "no other reward token specified in staking adapter");
        require(_adapter.lpTokenAddress() != address(0), "no staking token specified in staking adapter");
        _;
    }


    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        // nightg0at
        require(poolIsAdded[address(_lpToken)] == false, 'add: pool already added');
        poolIsAdded[address(_lpToken)] = true;

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accCropsPerShare: 0,
            // nightg0at
            accOtherPerShare: 0,
            adapter: IStakingAdapter(0),
            otherToken: IERC20(0)
        }));
    }

    // nightg0at
    // Add a new lp to the pool that uses restaking. Can only be called by the owner.
    function addWithRestaking(uint256 _allocPoint, bool _withUpdate, IStakingAdapter _adapter) public onlyOwner validAdapter(_adapter) {
        IERC20 _lpToken = IERC20(_adapter.lpTokenAddress());

        require(poolIsAdded[address(_lpToken)] == false, 'add: pool already added');
        poolIsAdded[address(_lpToken)] = true;
        
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accCropsPerShare: 0,
            accOtherPerShare: 0,
            adapter: _adapter,
            otherToken: IERC20(_adapter.rewardTokenAddress())
        }));
    }

    // Update the given pool's CROPS allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set a new restaking adapter.
    function setRestaking(uint256 _pid, IStakingAdapter _adapter, bool _claim) public onlyOwner validAdapter(_adapter) {
        if (_claim) {
            updatePool(_pid);
        }
        if (isRestaking(_pid)) {
            withdrawRestakedLP(_pid);
        }
        PoolInfo storage pool = poolInfo[_pid];
        require(address(pool.lpToken) == _adapter.lpTokenAddress(), "LP mismatch");
        pool.accOtherPerShare = 0;
        pool.adapter = _adapter;
        pool.otherToken = IERC20(_adapter.rewardTokenAddress());

        // transfer LPs to new target if we have any
        uint256 poolBal = pool.lpToken.balanceOf(address(this));
        if (poolBal > 0) {
            pool.lpToken.safeTransfer(address(pool.adapter), poolBal);
            pool.adapter.deposit(poolBal);
        }
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

    // View function to see pending CROPSs on frontend.
    function pendingCrops(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCropsPerShare = pool.accCropsPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        // nightg0at
        if (isRestaking(_pid)) {
            lpSupply = pool.adapter.balance();
        }
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 cropsReward = multiplier.mul(cropsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accCropsPerShare = accCropsPerShare.add(cropsReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accCropsPerShare).div(1e12).sub(user.rewardDebt);
    }

    // nightg0at
    // View function to see our pending OTHERs on frontend (whatever the restaked reward token is)
    function pendingOther(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accOtherPerShare = pool.accOtherPerShare;
        uint256 lpSupply = pool.adapter.balance();
 
        if (lpSupply != 0) {
            uint256 otherReward = pool.adapter.pending();
            accOtherPerShare = accOtherPerShare.add(otherReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accOtherPerShare).div(1e12).sub(user.otherRewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
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
        // nightg0at
        //uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 lpSupply = getPoolSupply(_pid);
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        // nightg0at
        if (isRestaking(_pid)) {
            uint256 pendingOtherTokens = pool.adapter.pending();
            if (pendingOtherTokens >= 0) {
                uint256 otherBalanceBefore = pool.otherToken.balanceOf(address(this));
                pool.adapter.claim();
                uint256 otherBalanceAfter = pool.otherToken.balanceOf(address(this));
                pendingOtherTokens = otherBalanceAfter.sub(otherBalanceBefore);
                pool.accOtherPerShare = pool.accOtherPerShare.add(pendingOtherTokens.mul(1e12).div(lpSupply));
            }
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cropsReward = multiplier.mul(cropsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        crops.mint(devaddr, cropsReward.div(10000).mul(teamRewardsrate));
        crops.mint(address(this), cropsReward);
        pool.accCropsPerShare = pool.accCropsPerShare.add(cropsReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // nightg0at
    // Internal view function to get the amount of LP tokens staked in the specified pool
    function getPoolSupply(uint256 _pid) internal view returns (uint256 lpSupply) {
        PoolInfo memory pool = poolInfo[_pid];
        if (isRestaking(_pid)) {
            lpSupply = pool.adapter.balance();
        } else {
            lpSupply = pool.lpToken.balanceOf(address(this));
        }
    }

    // nightg0at
    function isRestaking(uint256 _pid) public view returns (bool outcome) {
        if (address(poolInfo[_pid].adapter) != address(0)) {
            outcome = true;
        } else {
            outcome = false;
        }
    }


    // Deposit LP tokens to MasterChef for CROPS allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accCropsPerShare).div(1e12).sub(user.rewardDebt);
            safeCropsTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accCropsPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accCropsPerShare).div(1e12).sub(user.rewardDebt);
        /*
        safeCropsTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accCropsPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        */

        // nightg0at
        if(pending > 0) {
            safeCropsTransfer(msg.sender, pending);
        }
        uint256 otherPending = user.amount.mul(pool.accOtherPerShare).div(1e12).sub(user.otherRewardDebt);
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            if (isRestaking(_pid)) {
                pool.adapter.withdraw(_amount);
            }
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        //  we can't guarantee we have the tokens until after adapter.withdraw()
        if (otherPending > 0) {
            safeOtherTransfer(msg.sender, otherPending, _pid);
        }
        user.rewardDebt = user.amount.mul(pool.accCropsPerShare).div(1e12);
        user.otherRewardDebt = user.amount.mul(pool.accOtherPerShare).div(1e12);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        /*
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        */
        // nightg0at
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        if (isRestaking(_pid)) {
            pool.adapter.withdraw(amount);
        }
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // nightg0at
    // Withdraw LP tokens from the restaking target back here
    // Does not claim rewards
    function withdrawRestakedLP(uint256 _pid) internal {
        require(isRestaking(_pid), "not a restaking pool");
        PoolInfo storage pool = poolInfo[_pid];
        uint lpBalanceBefore = pool.lpToken.balanceOf(address(this));
        pool.adapter.emergencyWithdraw();
        uint lpBalanceAfter = pool.lpToken.balanceOf(address(this));
        emit EmergencyWithdraw(address(pool.adapter), _pid, lpBalanceAfter.sub(lpBalanceBefore));
    }

    // Safe crops transfer function, just in case if rounding error causes pool to not have enough CROPSs.
    function safeCropsTransfer(address _to, uint256 _amount) internal {
        uint256 cropsBal = crops.balanceOf(address(this));
        if (_amount > cropsBal) {
            crops.transfer(_to, cropsBal);
        } else {
            crops.transfer(_to, _amount);
        }
    }

    // nightg0at
    // as above but for any restaking token
    function safeOtherTransfer(address _to, uint256 _amount, uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 otherBal = pool.otherToken.balanceOf(address(this));
        if (_amount > otherBal) {
            pool.otherToken.transfer(_to, otherBal);
        } else {
            pool.otherToken.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
    
    // globalDecay function
    function globalDecay() public {
        timeend = now;
        uint256 timeinterval = timeend.sub(timestart);
        require(timeinterval > 21600, "timelimit-6hours is not finished yet");
        
        uint256 totaltokenamount = crops.totalSupply(); 
        totaltokenamount = totaltokenamount.sub(totaltokenamount.mod(1000));
        uint256 decaytokenvalue = totaltokenamount.div(1000);//1% of 10%decayvalue
        
        crops.globalDecay();
        crops.mint(msg.sender, decaytokenvalue);
        
        timestart = now;
        
    }
    
    // burn function
    function burn(address account, uint256 amount) public onlyOwner {
        crops._burn(account, amount);
    }
    
    //change the TPB(tokensPerBlock)
    function changetokensPerBlock(uint256 _newTPB) public onlyOwner {
        require(_newTPB <= maxtokenperblock, "too high value");
        cropsPerBlock = _newTPB;
    }
    
    //change the TBR(transBurnRate)
    function changetransBurnrate(uint256 _newtransBurnrate) public onlyOwner returns (bool) {
        crops.changetransBurnrate(_newtransBurnrate);
        return true;
    }
    
    //change the DBR(decayBurnrate)
    function changedecayBurnrate(uint256 _newdecayBurnrate) public onlyOwner returns (bool) {
        crops.changedecayBurnrate(_newdecayBurnrate);
        return true;
    }
    
    //change the TRR(teamRewardsRate)
    function changeteamRewardsrate(uint256 _newTRR) public onlyOwner {
        require(_newTRR <= maxteamRewardsrate, "too high value");
        teamRewardsrate = _newTRR;
    }
}