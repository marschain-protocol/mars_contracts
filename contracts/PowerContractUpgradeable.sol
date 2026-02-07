// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title IPowerNFT
 * @dev NFT合约接口，简化后只包含必要功能
 */
interface IPowerNFT {
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes memory data
    ) external;
    function balanceOf(
        address account,
        uint256 id
    ) external view returns (uint256);
}

/**
 * @title IterableMapping
 * @dev 可迭代的映射数据结构，用于存储每日算力数据
 */
library IterableMapping {
    struct Map {
        uint256[] keys;
        mapping(uint256 => uint256) values;
        mapping(uint256 => uint256) indexOf;
        mapping(uint256 => bool) inserted;
    }

    function get(Map storage map, uint256 key) internal view returns (uint256) {
        return map.values[key];
    }

    function getKeyAtIndex(
        Map storage map,
        uint256 index
    ) internal view returns (uint256) {
        return map.keys[index];
    }

    function size(Map storage map) internal view returns (uint256) {
        return map.keys.length;
    }

    function set(Map storage map, uint256 key, uint256 val) internal {
        if (map.inserted[key]) {
            map.values[key] = val;
        } else {
            map.inserted[key] = true;
            map.values[key] = val;
            map.indexOf[key] = map.keys.length;
            map.keys.push(key);
        }
    }
}

/**
 * @title PowerContractUpgradeable
 * @dev 算力系统主合约（UUPS可升级版本），实现完整的业务逻辑
 *
 * ==================== 核心功能 ====================
 * 1. 销毁代币获得算力，支持圣诞方程式倍数奖励
 * 2. 铸造NFT，需要累计销毁10000代币
 * 3. 建立NFT三层关联关系，奖励分配给上级用户
 * 4. 用户产币计算和提取
 * 5. 节点奖励分配管理
 * 6. 支持合约暂停和紧急操作
 * 7. 符合ERC1967Proxy标准的UUPS升级模式
 * 8. 操作账号可绕过限制为指定地址铸造NFT
 * 9. NFT绑定机制，每个用户只能绑定一个NFT
 *
 * ==================== 可升级特性 ====================
 *
 * 升级模式：UUPS（Universal Upgradeable Proxy Standard）
 * - 升级逻辑在实现合约中，不在代理合约中
 * - 比TransparentProxy更省gas
 * - 只有合约所有者可以升级
 *
 * 部署流程：
 * 1. 部署实现合约（PowerContractUpgradeable）
 * 2. 部署ERC1967Proxy代理合约，指向实现合约
 * 3. 通过代理合约调用initialize函数初始化
 * 4. 所有用户交互都通过代理合约进行
 *
 * 升级流程：
 * 1. 部署新的实现合约
 * 2. 调用代理合约的upgradeToAndCall函数
 * 3. 可选择性调用reinitialize函数迁移数据
 * 4. 原有数据和状态保持不变
 *
 * 存储布局注意事项：
 * - 不能修改已有状态变量的顺序
 * - 不能修改已有状态变量的类型
 * - 可以在末尾添加新的状态变量
 * - 预留了__gap数组用于未来扩展
 *
 * 安全考虑：
 * - 构造函数中调用_disableInitializers防止实现合约被初始化
 * - 只有owner可以升级合约
 * - 升级前请充分测试新实现合约
 * - 建议使用OpenZeppelin的升级插件验证存储布局
 */
contract PowerContractUpgradeable is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using IterableMapping for IterableMapping.Map;

    /**
     * @dev 构造函数 - 禁用实现合约的初始化
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ==================== 数据结构定义 ====================

    /**
     * @dev 用户信息结构
     */
    struct UserInfo {
        uint256 power; // 用户总算力
        uint256 burnedAmount; // 累计销毁代币数量（用于判断是否可铸造NFT）
        uint256 lastClaimTime; // 上次提取时间
        uint256 totalBurnedAmount; // 历史总销毁数量（不会重置，用于统计）
        uint256 boundNFT; // 用户绑定的NFT ID（0表示未绑定）
        address upline1; // 直接上级地址
        address upline2; // 二级上级地址
        IterableMapping.Map powerHistory; // 算力变化历史记录（day => power）,因为插入数据时key被push在最后，所以数据必须按时间顺序存放，不能后期插入到中间
        uint256 lastSettleDay; // 最后结算到哪一天
    }

    /**
     * @dev 圣诞方程式活动配置
     */
    struct ChristmasFormula {
        uint256 startYear; // 第一次活动年份（用于计算倍数），以后不会改变
        uint256 level; // 额外的倍数，每次手动开启后，level+1，用于计算倍数
        bool active; // 管理员手动激活标志（true时强制激活，false时按日期自动激活）
        mapping(uint256 => mapping(address => bool)) participatedByYear; // 用户是否已参与此次方程式
    }

    // ==================== 状态变量 ====================

    // 核心合约地址
    IPowerNFT public nftContract; // NFT合约地址

    // 用户相关数据
    mapping(address => UserInfo) internal users; // 用户信息映射
    mapping(address => uint256[]) public userNFTs; // 用户拥有的NFT列表

    // NFT所有权追踪
    mapping(uint256 => address) public nftOwner; // NFT所有者映射（用于O(1)查询）
    mapping(address => mapping(uint256 => uint256)) private nftIndexInUserList; // NFT在用户列表中的索引（用于O(1)删除）

    // 算力历史数据（只存储总算力，用户算力在UserInfo.powerHistory中）
    IterableMapping.Map private dailyTotalPower; // 每日总算力

    // 活动和节点配置
    ChristmasFormula public christmasFormula; // 圣诞方程式配置

    // 节点管理员配置
    uint256 public constant BIG_NODE_SEATS = 1200; // 大节点席位数量
    uint256 public constant SMALL_NODE_SEATS = 1000; // 小节点席位数量
    uint256 public constant NODE_SEATS = BIG_NODE_SEATS + SMALL_NODE_SEATS; // 节点总席位数量
    mapping(uint256 => address) public nodeWithdrawAddress; // 节点席位提币地址（seatIndex => address）
    uint256 public totalNodeRewards; // 总的node奖励池
    mapping(uint256 => uint256) public nodeWithdrawn; // 每个席位已提取的总额（index => amount）

    // 系统参数（可配置）
    uint256 public burnRequirementForNFT; // 铸造NFT需要的销毁代币数量
    uint256 public powerCalculationDays; // 算力计算天数
    uint256 public maxClaimDays; // 单次最多可提取的天数（防止gas耗尽）

    // 系统状态
    uint256 public totalPower; // 全网总算力
    uint256 public currentDay; // 当前天数
    uint256 public nftIdCounter; // NFT ID 计数器
    uint256 public totalBurnedTokens; // 历史总销毁代币数量
    uint256 public totalClaimed; // 用户提取总额
    uint256 public firstDataDay; // 第一个有数据的天数（用于判断查询日期是否在系统启动之前）
    uint256 public currentBlock; // 当前已stamp的区块号
    mapping(uint256 => uint256) public dateEmission; // 每日产币量

    // 常量定义
    uint256 public constant BIG_NODE_ALLOCATION_PERCENT = 20; // 大节点分配比例
    uint256 public constant SMALL_NODE_ALLOCATION_PERCENT = 5; // 小节点分配比例
    uint256 public constant NODE_ALLOCATION_PERCENT =
        BIG_NODE_ALLOCATION_PERCENT + SMALL_NODE_ALLOCATION_PERCENT; // 节点总分配比例
    uint256 public constant USER_ALLOCATION_PERCENT =
        100 - NODE_ALLOCATION_PERCENT; // 用户分配比例（剩余）
    uint256 public constant UPLINE1_BONUS_PERCENT = 50; // 直接上级奖励比例
    uint256 public constant UPLINE2_BONUS_PERCENT = 25; // 二级上级奖励比例
    uint256 public constant MAX_TOTAL_POWER = 1e60; // 最大总算力
    uint256 public constant MAX_SINGLE_BURN = 1e50; // 单次最大销毁数量
    uint256 public constant MIN_BURN_AMOUNT = 1e17; // 最小销毁数量（0.1代币）

    // 黑洞地址
    address public constant BURN_ADDRESS =
        0x0000000000000000000000000000000000000000;

    // 合约版本
    uint256 public version;

    // 操作员管理
    address public operator; // 操作员地址，可以给任意地址添加算力

    // NFT绑定追踪（防止一个NFT被多人绑定）
    mapping(uint256 => address) public nftBoundTo; // NFT绑定给哪个用户（0地址表示未绑定）

    // 系统启动状态（用于区分空投阶段和正式运营阶段）
    bool public started; // false: 空投阶段，true: 正式运营

    // ==================== 事件定义 ====================

    event TokensBurned(
        address indexed user,
        uint256 amount,
        uint256 powerGained
    );
    event ChristmasTokensBurned(
        address indexed user,
        uint256 indexed year,
        uint256 amount,
        uint256 powerGained
    );
    event PowerUpdated(
        address indexed user,
        uint256 newPower,
        uint256 newTotalPower
    );
    event NFTMinted(address indexed user, uint256 indexed tokenId);
    event RelationEstablished(
        uint256 indexed nftId,
        address indexed to,
        address upline1,
        address upline2
    );
    event TokensClaimed(address indexed user, uint256 amount);
    event ChristmasFormulaUpdated(
        uint256 startYear,
        uint256 level,
        bool active
    );
    event SystemParameterUpdated(
        string parameter,
        uint256 oldValue,
        uint256 newValue
    );
    event ContractUpgraded(uint256 oldVersion, uint256 newVersion);
    event NodeAdminUpdated(uint256 indexed index, address indexed admin);
    event NodeRewardClaimed(address indexed admin, uint256 amount);
    event RewardsSettled(
        address indexed user,
        uint256 amount,
        uint256 settledToDay
    );
    event OperatorUpdated(
        address indexed oldOperator,
        address indexed newOperator
    );
    event PowerAddedByOperator(
        address indexed operator,
        address indexed user,
        uint256 powerAmount,
        uint256 newUserPower,
        uint256 newTotalPower
    );

    event RelationAndPowerInitialized(
        address indexed user,
        address indexed upline1,
        address indexed upline2,
        uint256 powerAmount,
        uint256 coins
    );

    event SystemStarted();

    // ------------------------------------------------------------------------
    // Calculate year/month/day from the number of days since 1970/01/01 using
    // the date conversion algorithm from
    //   http://aa.usno.navy.mil/faq/docs/JD_Formula.php
    // and adding the offset 2440588 so that 1970/01/01 is day 0
    //
    // int L = days + 68569 + offset
    // int N = 4 * L / 146097
    // L = L - (146097 * N + 3) / 4
    // year = 4000 * (L + 1) / 1461001
    // L = L - 1461 * year / 4 + 31
    // month = 80 * L / 2447
    // dd = L - 2447 * month / 80
    // L = month / 11
    // month = month + 2 - 12 * L
    // year = 100 * (N - 49) + year + L
    // ------------------------------------------------------------------------
    uint constant SECONDS_PER_DAY = 24 * 60 * 60;
    int constant OFFSET19700101 = 2440588;
    function daysToDate(
        uint timestamp
    ) internal pure returns (uint year, uint month, uint day) {
        int __days = int(timestamp / SECONDS_PER_DAY);
        int L = __days + 68569 + OFFSET19700101;
        int N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        int _month = (80 * L) / 2447;
        int _day = L - (2447 * _month) / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        year = uint(_year);
        month = uint(_month);
        day = uint(_day);
    }

    // ==================== 修饰符 ====================

    /**
     * @dev 只允许NFT合约调用
     */
    modifier onlyNFTContract() {
        require(
            msg.sender == address(nftContract),
            "Only NFT contract can call"
        );
        _;
    }

    /**
     * @dev 只允许操作员调用
     */
    modifier onlyOperator() {
        require(
            msg.sender == operator && operator != address(0),
            "Only operator can call"
        );
        _;
    }

    /**
     * @dev 更新每日数据
     */
    modifier updateDaily() {
        _updateDailyData();
        _;
    }

    /**
     * @dev 检查系统限制
     */
    modifier checkSystemLimits() {
        require(totalPower < MAX_TOTAL_POWER, "System power limit reached");
        _;
    }

    /**
     * @dev 只允许系统未启动时调用（空投阶段）
     */
    modifier whenNotStarted() {
        require(!started, "System already started");
        _;
    }

    /**
     * @dev 只允许系统已启动时调用（正式运营阶段）
     */
    modifier whenStarted() {
        require(started, "System not started yet");
        _;
    }

    // ==================== 初始化函数 ====================

    /**
     * @dev 初始化函数，替代构造函数 - 部署后必须调用一次
     *
     * 功能说明：
     * - 可升级合约不能使用constructor，必须使用initialize
     * - 通过代理合约部署后，必须立即调用此函数
     * - 此函数只能调用一次（initializer修饰符保证）
     *
     * 初始化内容：
     * 1. 初始化所有继承的合约：
     *    - Ownable：设置合约所有者
     *    - Pausable：初始化暂停状态
     *    - ReentrancyGuard：初始化重入锁
     *    - UUPSUpgradeable：初始化升级功能
     *
     * 2. 设置核心变量：
     *    - currentDay：当前天数
     *    - version：合约版本号（初始为1）
     *    - nftIdCounter：NFT ID计数器（从0开始）
     *    - totalBurnedTokens：总销毁代币数（初始为0）
     *
     * 3. 初始化系统参数（使用默认值）：
     *    - burnRequirementForNFT = 10000代币
     *    - dailyEmissionRate = 100万代币/天
     *    - powerCalculationDays = 188天
     *    - maxClaimDays = 30天
     *
     * 调用时机：
     * - 必须在部署代理合约后立即调用
     * - 建议在同一个交易中完成部署和初始化
     * - 可以使用OpenZeppelin的deployProxy函数自动完成
     *
     * 后续配置：
     * - NFT合约地址在初始化时设置，后续可通过setNFTContract修改
     * - 系统参数可以通过setSystemParameter调整
     * - 节点管理员地址通过setNodeAdmin设置
     *
     * 注意事项：
     * - 此函数只能调用一次，无法重复初始化
     * - 初始化失败会导致合约无法使用
     * - 确保参数正确后再调用
     *
     * 安全考虑：
     * - initializer修饰符防止重复初始化
     * - 只有通过代理合约才能成功调用
     * - 部署者自动成为合约所有者
     */
    function initialize() public initializer {
        __Ownable_init(0x3316cB60079cA0cB8A704D85b4ce5777eeB22Fe0);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        currentDay = _getCurrentDay();
        firstDataDay = currentDay;
        version = 1;
        nftIdCounter = 0;
        totalBurnedTokens = 0;

        // 初始化系统参数
        burnRequirementForNFT = 10000 * 10 ** 18;
        powerCalculationDays = 188;
        maxClaimDays = 180;
        totalClaimed = 0; // 全新部署从0开始
        
        // 初始化圣诞节活动起始年份
        (uint year, , ) = daysToDate(block.timestamp);
        christmasFormula.startYear = year;
        emit ChristmasFormulaUpdated(
            christmasFormula.startYear,
            christmasFormula.level,
            christmasFormula.active
        );
    }

    /**
     * @dev 重新初始化函数，用于升级时的数据迁移或新功能初始化
     * @param _newVersion 新版本号
     *
     * 在合约升级后可以调用，用于初始化新功能或迁移数据
     * 版本号必须递增，每个版本号只能初始化一次
     */
    function reinitialize(
        uint256 _newVersion
    ) public reinitializer(uint8(_newVersion)) {
        uint256 oldVersion = version;
        version = _newVersion;
        emit ContractUpgraded(oldVersion, _newVersion);
    }

    // ==================== 升级授权 ====================

    /**
     * @dev 升级授权检查 - UUPS模式的核心安全机制
     * @param newImplementation 新实现合约的地址
     *
     * 只有合约所有者可以升级合约
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
    
    receive() external payable {
        //revert("PowerContract: cannot receive ether");
    }

    /**
     * @dev 标记新区块以进行产币计算，每次出块时被coinbase调用
     */
    function stamp() external {
        if (currentBlock < block.number) {
            uint256 reward = 0;
            for (uint256 i = currentBlock + 1; i <= block.number; i++) {
                uint256 blockReward = getBlockReward(i);
                reward += blockReward;
            }
            //处理总产币
            uint256 today = _getCurrentDay();
            dateEmission[today] += reward;
            _processNewCoins(reward);

            //当前日期第一个区块记录总算力,避免当日无新增算力影响历史算力查询。当日的总算力增加在_updateUserPower实现
            if (dailyTotalPower.get(today) == 0){
                dailyTotalPower.set(today, totalPower);
            }
            currentBlock = block.number;
        }
    }
    
    /// @notice Returns the block reward based on the current block number.
    /// @dev Initial reward is 7,750,496,031,750,000,000,000, then halves every 12,902,400 blocks.
    /// @notice halvingOffset is the number of blocks skipped, all rewards in these blocks are pre-allocated in genesis block
    function getBlockReward(uint256 blockNumber) public pure returns (uint256) {
        uint256 baseReward = 7750496031750000000000;
        // 减半周期（区块数）
        uint256 halvingBlock = 28800 * 448; // 12,902,400 区块
        uint256 halvingOffset = 77420;  
        uint256 halvingCount = (blockNumber + halvingOffset) / halvingBlock;
        uint256 reward = baseReward >> halvingCount;
        return reward;
    }
    /**
     * @dev 内部函数：检查并处理新转入的原生币
     */
    function _processNewCoins(uint256 newCoins) private {
        // 分配比例：25%给节点池
        uint256 toNodes = (newCoins * NODE_ALLOCATION_PERCENT) / 100;
        // 记录节点奖励
        if (toNodes > 0) {
            _recordNodeRewards(toNodes);
        }
        
    }

    // ==================== 核心业务功能 ====================

    /**
     * @dev 销毁原生币获得算力
     * @param _nftId 用于销毁的NFT ID
     *
     * 功能逻辑：
     * 1. 检查NFT绑定状态（首次使用自动绑定）
     * 2. 验证用户拥有该NFT
     * 3. 销毁用户原生币到黑洞地址
     * 4. 计算获得的算力
     * 5. 根据用户的上下级关系分配算力奖励
     */
    function burn(
        uint256 _nftId
    )
        external
        payable
        whenNotPaused
        whenStarted
        nonReentrant
        updateDaily
        checkSystemLimits
    {
        //判断圣诞方程式没有开启，开启了不可以执行销毁
        require(
            !_isChristmasFormulaActive(),
            "Christmas event is active, cannot burn"
        );

        uint256 _amount = msg.value;
        require(_amount >= MIN_BURN_AMOUNT, "Burn amount too small");
        require(_amount <= MAX_SINGLE_BURN, "Burn amount too large");

        // 检查NFT绑定逻辑
        if (users[msg.sender].boundNFT == 0) {
            // 第一次绑定NFT
            // 1. 检查该NFT是否已被其他人绑定
            require(
                nftBoundTo[_nftId] == address(0),
                "NFT already bound to another user"
            );

            // 2. 检查用户是否拥有该NFT
            require(
                nftContract.balanceOf(msg.sender, _nftId) > 0,
                "Must own the NFT to bind it"
            );

            // 3. 绑定NFT到当前用户
            users[msg.sender].boundNFT = _nftId;
            nftBoundTo[_nftId] = msg.sender;
        } else {
            // 已绑定NFT，必须使用绑定的NFT
            require(users[msg.sender].boundNFT == _nftId, "Must use bound NFT");
        }

        // 销毁原生币到黑洞地址
        (bool success, ) = BURN_ADDRESS.call{value: _amount}("");
        require(success, "Burn failed");

        // 计算算力（普通销毁没有倍数加成）
        uint256 addedPower = _calculatePowerFromBurn(_amount);

        _updateUserPower(msg.sender, addedPower);
        users[msg.sender].burnedAmount += _amount;
        users[msg.sender].totalBurnedAmount += _amount;
        totalBurnedTokens += _amount;

        // 分配上级奖励（使用用户的关系，而不是NFT的关系）
        _distributeUplineRewards(msg.sender, addedPower);

        emit TokensBurned(msg.sender, _amount, addedPower);
        emit PowerUpdated(msg.sender, users[msg.sender].power, totalPower);
    }

    /**
     * @dev 铸造NFT
     *
     * 条件：
     * 1. 用户累计销毁代币达到要求（10000个代币）
     * 2. 用户已绑定NFT（必须先使用NFT销毁才能铸造）
     * 3. 可以铸造任意数量的NFT
     */
    function mintNFT() external whenNotPaused whenStarted nonReentrant {
        require(address(nftContract) != address(0), "NFT contract not set");
        require(
            users[msg.sender].burnedAmount >= burnRequirementForNFT,
            "Insufficient burned tokens for NFT"
        );
        // 铸造NFT
        uint256 tokenId = ++nftIdCounter;
        nftContract.mint(msg.sender, tokenId, 1, "");

        // 更新用户NFT记录
        nftIndexInUserList[msg.sender][tokenId] = userNFTs[msg.sender].length;
        userNFTs[msg.sender].push(tokenId);
        nftOwner[tokenId] = msg.sender;

        emit NFTMinted(msg.sender, tokenId);
    }

    /**
     * @dev 操作账号为指定地址铸造NFT
     * @param to 接收NFT的地址
     *
     * 功能：
     * - 仅操作账号可调用，绕过所有限制
     * - 可以给任意地址铸造NFT
     */
    function mintNFTByOperator(
        address to
    ) external whenNotPaused whenStarted nonReentrant onlyOperator {
        require(to != address(0), "Invalid recipient address");
        require(address(nftContract) != address(0), "NFT contract not set");

        // 铸造NFT
        uint256 tokenId = ++nftIdCounter;
        nftContract.mint(to, tokenId, 1, "");

        // 更新用户NFT记录
        nftIndexInUserList[to][tokenId] = userNFTs[to].length;
        userNFTs[to].push(tokenId);
        nftOwner[tokenId] = to;

        emit NFTMinted(to, tokenId);
    }

    /**
     * @dev 圣诞节活动专用销毁方法
     * @param _nftId 用于销毁的NFT ID
     *
     * 功能说明：
     * - 每年12月25日到次年1月5日自动激活
     * - 用户销毁固定数量的代币（算力 * 销毁因子）
     * - 获得递增倍数算力
     * - 每个用户每年只能参与一次
     *
     * 倍数规则：
     * - 第1年：10倍
     * - 第2年：20倍
     * - 第3年：40倍
     * - 以此类推（2^(年份差) × 10）
     *
     * 销毁因子计算：流通代币的节点总分配比例 / 总算力
     * 用户销毁数量：用户算力 * 销毁因子
     * 获得算力：销毁数量对应的基础算力 * 倍数
     */
    function burnChristmas(
        uint256 _nftId
    )
        external
        payable
        whenNotPaused
        whenStarted
        nonReentrant
        updateDaily
        checkSystemLimits
    {
        // 验证活动是否激活
        require(_isChristmasFormulaActive(), "Christmas event is not active");

        (uint christmasYear, , ) = daysToDate(block.timestamp);

        uint256 christmasMultiplier = getCurrentChristmasMultiplier(
            christmasYear
        );

        // 验证用户本年度是否已参与
        require(
            !hasParticipatedChristmas(msg.sender, christmasMultiplier), //一年可能有多次，但倍数相同只允许参与一次
            "Already participated in this event"
        );

        // 验证用户必须有算力才能参与
        require(users[msg.sender].power > 0, "No power to participate");

        // 检查NFT绑定逻辑
        if (users[msg.sender].boundNFT == 0) {
            // 第一次绑定NFT
            // 1. 检查该NFT是否已被其他人绑定
            require(
                nftBoundTo[_nftId] == address(0),
                "NFT already bound to another user"
            );

            // 2. 检查用户是否拥有该NFT
            require(
                nftContract.balanceOf(msg.sender, _nftId) > 0,
                "Must own the NFT to bind it"
            );

            // 3. 绑定NFT到当前用户
            users[msg.sender].boundNFT = _nftId;
            nftBoundTo[_nftId] = msg.sender;
        } else {
            // 已绑定NFT，必须使用绑定的NFT
            require(users[msg.sender].boundNFT == _nftId, "Must use bound NFT");
        }

        // 计算用户应该销毁的固定数量
        uint256 requiredBurnAmount = _calculateChristmasBurnAmount(
            msg.sender,
            msg.value
        );
        require(requiredBurnAmount > 0, "Invalid burn amount");

        // 验证发送的金额是否正确
        require(
            msg.value >= requiredBurnAmount,
            "Incorrect burn amount for Christmas event"
        );

        uint256 addedPower = users[msg.sender].power *
            (christmasMultiplier - 1);

        // 更新用户数据（增加算力）
        _updateUserPower(msg.sender, addedPower);
        users[msg.sender].totalBurnedAmount += requiredBurnAmount;
        totalBurnedTokens += requiredBurnAmount;
        
        // 分配上级奖励（使用用户的关系），传入新增的算力
        _distributeUplineRewards(msg.sender, addedPower);
        // 标记用户本年度已参与
        christmasFormula.participatedByYear[christmasMultiplier][
            msg.sender
        ] = true;
        
        // 销毁原生币到黑洞地址
        (bool success, ) = BURN_ADDRESS.call{value: requiredBurnAmount}("");
        require(success, "Burn failed");
        //退还多余部分
        (success, ) = msg.sender.call{value: msg.value - requiredBurnAmount}(
            ""
        ); 
        require(success, "Refund failed");

        emit ChristmasTokensBurned(
            msg.sender,
            christmasYear,
            requiredBurnAmount,
            addedPower
        );
        emit PowerUpdated(msg.sender, users[msg.sender].power, totalPower);
    }

    /**
     * @dev 建立用户关联关系（由NFT合约转账时回调）
     * @param _from 转出地址
     * @param _to 接收地址
     * @param _tokenId NFT ID
     *
     * 关系建立规则：
     * 1. 只有孤立用户（没有上级关系）才会被建立关系
     * 2. 建立两层上级关系链：上家50%，上上家25%
     * 3. 关系存储在用户级别，一旦确定不会改变
     * 4. 更新用户NFT持有列表
     */
    function makeRelation(
        address _from,
        address _to,
        uint256 _tokenId
    ) external onlyNFTContract whenNotPaused whenStarted {
        // 更新用户NFT列表
        _updateUserNFTList(_from, _to, _tokenId);

        // 只有孤立用户（接收者没有关联关系）才建立关系，且转出转入地址不同
        if (
            users[_to].upline1 == address(0) &&
            _from != _to &&
            _from != address(0)
        ) {
            users[_to].upline1 = _from; // 转让者成为直接上级
            users[_to].upline2 = users[_from].upline1; // 转让者的上级成为二级上级

            emit RelationEstablished(
                _tokenId,
                _to,
                _from,
                users[_from].upline1
            );
        }
    }

    // 操作员建立关系用于数据冷启动，但是不涉及nft
    function makeRelationByOperator(
        address _from,
        address _to
    ) external onlyOperator whenNotPaused whenStarted {
        users[_to].upline1 = _from;
        users[_to].upline2 = users[_from].upline1;
    }

    /**
     * @dev 操作员批量建立关系并初始化用户算力（不分配upline算力）
     * @param _users 用户数组
     * @param _upline1s 用户数组 //upline1数组
     * @param _upline2s 二级上级数组 //upline2数组
     * @param _powerAmounts 初始化算力数组（为用户增加算力）
     * @param _coins 初始化原生币数组（为用户增加原生币）
     *
     * 注意：
     * - 本方法只更新用户自身算力与全网总算力，不触发上下级算力分配
     * - 本方法不触发上下级算力分配
     * - 本方法不触发节点奖励分配
     * - 本方法不触发圣诞方程式奖励分配
     */
    function batchMakeRelationAndInitPowerByOperator(
        address[] calldata _users,
        address[] calldata _upline1s,
        address[] calldata _upline2s,
        uint256[] calldata _powerAmounts,
        uint256[] calldata _coins
    )
        external
        onlyOperator
        whenNotStarted
        nonReentrant
        updateDaily
        checkSystemLimits
    {
        require(
            _users.length == _upline1s.length &&
                _upline1s.length == _upline2s.length &&
                _upline2s.length == _powerAmounts.length &&
                _upline2s.length == _coins.length,
            "Invalid array length"
        );

        uint256 totalInitCoins = 0;
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            address upline1 = _upline1s[i];
            address upline2 = _upline2s[i];
            uint256 powerAmount = _powerAmounts[i];
            uint256 coins = _coins[i];

            require(user != address(0), "User address cannot be zero");

            // 建立关系（与 makeRelationByOperator 保持一致）
            users[user].upline1 = upline1;
            users[user].upline2 = upline2;

            // 增加用户算力（不触发 upline 分配）
            _updateUserPower(user, powerAmount);

            //初始化发币，转给用户
            if (coins > 0) {
                require(
                    address(this).balance >= coins,
                    "Insufficient contract balance"
                );
                (bool success, ) = user.call{value: coins}("");
                require(success, "Transfer coins failed");
                totalInitCoins += coins;
            }
            emit RelationAndPowerInitialized(
                user,
                upline1,
                upline2,
                powerAmount,
                coins
            );
        }

        // 将初始化转出的原生币计入"已提取总额"
        if (totalInitCoins > 0) {
            totalClaimed += totalInitCoins;
        }
    }

    /**
     * @dev 查看用户所有可提取的币（view函数）
     * @param _user 用户地址
     * @return 用户可提取的总金额（已结算 + 未结算）
     *
     * 功能说明：
     * - 加上从上次结算日到今天的未结算奖励
     * - 纯查询函数，不修改状态
     *
     * 注意事项：
     * - 如果未结算天数过多（>365天），RPC查询可能超时
     * - 这是正常现象，不影响安全性，不影响实际提取
     * - 超时时可以直接调用 claimTokens() 进行分批提取
     */
    function viewClaimable(
        address _user,
        uint256 _endDay
    ) external view returns (uint256) {
        UserInfo storage userInfo = users[_user];
        // 调用内部函数计算奖励
        uint256 startDay = 0;
        if (userInfo.lastSettleDay == 0) {
            // 首次计算，从第一条算力记录开始
            if (userInfo.powerHistory.size() > 0) {
                startDay = userInfo.powerHistory.getKeyAtIndex(0);
            } else {
                return 0; // 没有算力记录，直接返回0
            }
        } else {
            // 从上次结算的下一天开始
            startDay = userInfo.lastSettleDay + 1;
        }

        uint256 today = _getCurrentDay();
        uint256 endDay = _endDay >= today ? today - 1 : _endDay;

        return _calculateRewards(userInfo, startDay, endDay);
    }

    /**
     * @dev 结算并提取产币（支持分批提取，防止gas超限）
     * @return settledToDay 本次结算到哪一天
     * @return todayDay 当前天数
     * @return claimedAmount 本次提取的金额
     *
     * 功能说明：
     * - 自动结算从上次结算日到昨天的奖励（限制最多 maxClaimDays 天）
     * - 提取已结算余额中的原生币
     * - 如果未结算天数超过 maxClaimDays，可以多次调用继续结算
     * - 每次调用都会提取当前所有已结算余额
     *
     * 使用场景：
     * - 用户长时间未提取，可能有几百天的奖励未结算
     * - 一次性结算所有天数可能gas不够
     * - 用户可以多次调用此函数，每次结算 maxClaimDays 天并提取
     * - 直到 settledToDay == todayDay-1，表示全部结算完成
     *
     * 返回值说明：
     * - settledToDay: 已结算到哪一天
     * - todayDay: 当前天数
     * - claimedAmount: 本次提取的金额（可能为0，如果没有已结算余额）
     *
     * 重要说明：
     * - 只结算到昨天，今天的奖励必须等到明天才能提取
     * - 这样设计是为了避免同一天内多次结算导致的重复计算
     * - 算力变化在当天结束时统一结算，逻辑清晰
     */
    function claimTokens()
        external
        whenNotPaused
        whenStarted
        nonReentrant
        updateDaily
        returns (uint256, uint256, uint256)
    {

        UserInfo storage userInfo = users[msg.sender];
        // 调用内部函数计算奖励
        uint256 startDay = 0;
        if (userInfo.lastSettleDay == 0) {
            // 首次计算，从第一条算力记录开始
            if (userInfo.powerHistory.size() > 0) {
                startDay = userInfo.powerHistory.getKeyAtIndex(0);
            } else {
                return (0, 0, 0); // 没有算力记录，直接返回0
            }
        } else {
            // 从上次结算的下一天开始
            startDay = userInfo.lastSettleDay + 1;
        }

        uint256 yesterday = _getCurrentDay() - 1;
        uint256 endDay = (yesterday + 1 - startDay) > maxClaimDays // 第一天claim时候避免underflow
            ? startDay + maxClaimDays - 1
            : yesterday;

        // 第一步：结算奖励（如果有未结算的天数）
        uint256 rewards = _calculateRewards(userInfo, startDay, endDay);

        // 第二步：提取已结算的余额

        if (rewards > 0) {
            require(
                address(this).balance >= rewards,
                "Insufficient contract balance"
            );

            // 更新提取时间
            userInfo.lastClaimTime = block.timestamp;
            userInfo.lastSettleDay = endDay;
            // 记录settle日的算力,方便下次提取时使用
            // 不能直接set endDay的算力，因为endDay可能在powerHistory的中间位置
            // if (userInfo.powerHistory.get(endDay) == 0) {
            //     userInfo.powerHistory.set(
            //         endDay,
            //         _getUserPowerForDay(userInfo, endDay)
            //     );
            // }
            // 累加用户提取总额
            totalClaimed += rewards;

            // 转账原生币给用户
            (bool success, ) = msg.sender.call{value: rewards}("");
            require(success, "Transfer failed");

            emit TokensClaimed(msg.sender, rewards);
        }

        return (startDay, endDay, rewards);
    }

    // ==================== 查询功能 ====================

    /**
     * @dev 查看用户算力信息
     * @param _user 用户地址
     * @return userPower 用户算力
     * @return totalPower_ 总算力
     */
    function viewPower(
        address _user
    ) external view returns (uint256 userPower, uint256 totalPower_) {
        return (users[_user].power, totalPower);
    }

    /**
     * @dev 获取用户关系信息
     * @param _user 用户地址
     * @return upline1 直接上级地址
     * @return upline2 二级上级地址
     */
    function getRelation(
        address _user
    ) external view returns (address upline1, address upline2) {
        return (users[_user].upline1, users[_user].upline2);
    }

    /**
     * @dev 获取用户基本信息（不包括算力历史）
     * @param _user 用户地址
     * @return power 用户算力
     * @return burnedAmount 累计销毁代币数量
     * @return lastClaimTime 上次提取时间
     * @return totalBurnedAmount 历史总销毁数量
     * @return boundNFT 用户绑定的NFT ID
     * @return upline1 直接上级地址
     * @return upline2 二级上级地址
     * @return lastSettleDay 最后结算到哪一天
     */
    function getUserInfo(
        address _user
    )
        external
        view
        returns (
            uint256 power,
            uint256 burnedAmount,
            uint256 lastClaimTime,
            uint256 totalBurnedAmount,
            uint256 boundNFT,
            address upline1,
            address upline2,
            uint256 lastSettleDay
        )
    {
        UserInfo storage info = users[_user];
        return (
            info.power,
            info.burnedAmount,
            info.lastClaimTime,
            info.totalBurnedAmount,
            info.boundNFT,
            info.upline1,
            info.upline2,
            info.lastSettleDay
        );
    }

    /**
     * @dev 获取当前圣诞方程式倍数
     * @param _currentYear 年份
     * @return 当前倍数（未激活时返回1，激活时返回 2^第几次 × 10）
     */
    function getCurrentChristmasMultiplier(
        uint256 _currentYear
    ) public view returns (uint256) {
        if (_isChristmasFormulaActive()) {
            // 圣诞节活动倍数 = 2^level × 10, level=当前年份-起始年份+手动开启次数
            // 第一年：10倍，第二年：20倍，第三年：40倍
            return
                (2 **
                    (_currentYear -
                        christmasFormula.startYear +
                        christmasFormula.level)) * 10;
        }
        return 1;
    }

    /**
     * @dev 检查用户是否已参与本年度圣诞活动
     * @param _user 用户地址
     * @param _christmasMultiplier 当前倍数
     * @return 是否已参与本年度活动
     */
    function hasParticipatedChristmas(
        address _user,
        uint256 _christmasMultiplier
    ) public view returns (bool) {
        return christmasFormula.participatedByYear[_christmasMultiplier][_user];
    }

    /**
     * @dev 获取用户在本年度圣诞活动中的销毁信息
     * @param _user 用户地址
     * @param _currentYear 年份
     * @return requiredAmount 需要销毁的固定数量
     * @return canParticipate 是否可以参与
     */
    function getUserChristmasBurnInfo(
        address _user,
        uint256 _currentYear
    ) external view returns (uint256 requiredAmount, bool canParticipate) {
        if (!_isChristmasFormulaActive()) {
            return (0, false);
        }

        // 计算需要销毁的固定数量
        requiredAmount = _calculateChristmasBurnAmount(_user, 0);

        // 判断是否可以参与
        uint256 christmasMultiplier = getCurrentChristmasMultiplier(
            _currentYear
        );
        canParticipate =
            !hasParticipatedChristmas(_user, christmasMultiplier) &&
            users[_user].power > 0 &&
            requiredAmount > 0 &&
            _user.balance >= requiredAmount;

        return (requiredAmount, canParticipate);
    }

    /**
     * @dev 获取圣诞活动信息
     * @param _currentYear 年份
     * @return active 是否激活
     * @return startYear 起始年份
     * @return multiplier 当前倍数（2^第几次 × 10）
     */
    function getChristmasInfo(
        uint256 _currentYear
    )
        external
        view
        returns (bool active, uint256 startYear, uint256 multiplier)
    {
        return (
            _isChristmasFormulaActive(),
            christmasFormula.startYear,
            (2 **
                (_currentYear -
                    christmasFormula.startYear +
                    christmasFormula.level)) * 10
        );
    }

    /**
     * @dev 获取算力计算所需的参数（供前端缓存使用，避免频繁调用）
     * @return totalPower_ 当前总算力
     * @return currentDayEmission 当前每日产币量
     * @return powerCalculationDays_ 算力计算天数
     * @return userAllocationPercent 用户分配比例
     *
     * 前端可以用这些参数自己计算：
     * basePower = (burnAmount × totalPower) / (currentDayEmission × userAllocationPercent / 100 × powerCalculationDays)
     */
    function getPowerCalculationParams()
        external
        view
        returns (
            uint256 totalPower_,
            uint256 currentDayEmission,
            uint256 powerCalculationDays_,
            uint256 userAllocationPercent
        )
    {
        return (
            totalPower,
            _getDailyEmission(_getCurrentDay()),
            powerCalculationDays,
            USER_ALLOCATION_PERCENT
        );
    }

    /**
     * @dev 检查NFT是否已被绑定（用于NFT合约判断是否可转让）
     * @param _nftId NFT ID
     * @return 是否已被绑定（绑定后不可转让）
     */
    function isNFTUsed(uint256 _nftId) external view returns (bool) {
        return nftBoundTo[_nftId] != address(0);
    }

    /**
     * @dev 获取系统统计信息
     * @return totalBurned 总销毁代币数量
     * @return totalPower_ 总算力
     * @return dailyEmission 每日产币量
     */
    function getSystemStats()
        external
        view
        returns (
            uint256 totalBurned,
            uint256 totalPower_,
            uint256 dailyEmission
        )
    {
        uint256 _day = _getCurrentDay();
        uint256 dailyEmissionRate = _getDailyEmission(_day);
        return (totalBurnedTokens, totalPower, dailyEmissionRate);
    }

    /**
     * @dev 获取用户拥有的NFT列表
     * @param _user 用户地址
     * @return NFT ID数组
     *
     * 注意：
     * - 如果用户拥有的NFT数量很多（>100个），建议使用分页查询 getUserNFTsPaginated
     * - 返回完整数组可能消耗较多gas（在交易中调用时）或导致RPC查询超时
     */
    function getUserNFTs(
        address _user
    ) external view returns (uint256[] memory) {
        return userNFTs[_user];
    }

    /**
     * @dev 分页获取用户拥有的NFT列表
     * @param _user 用户地址
     * @param _offset 偏移量（从0开始）
     * @param _limit 每页数量（建议≤100，0表示返回从offset到末尾的所有数据）
     * @return nftIds NFT ID数组
     * @return total 总数量
     *
     * 用途：
     * - 分页查询大量NFT
     * - 避免单次查询过多数据导致超时或gas过高
     * - 支持前端分页展示
     *
     * 示例：
     * ```
     * // 查询第1页，每页20个
     * (nftIds, total) = getUserNFTsPage(user, 0, 20);
     *
     * // 查询第2页
     * (nftIds, total) = getUserNFTsPage(user, 20, 20);
     *
     * // 查询所有剩余数据（从第50个开始）
     * (nftIds, total) = getUserNFTsPage(user, 50, 0);
     * ```
     */
    function getUserNFTsPage(
        address _user,
        uint256 _offset,
        uint256 _limit
    ) external view returns (uint256[] memory nftIds, uint256 total) {
        uint256[] storage allNFTs = userNFTs[_user];
        total = allNFTs.length;

        // 如果偏移量超出范围，返回空数组
        if (_offset >= total) {
            return (new uint256[](0), total);
        }

        // 计算实际返回的数量
        uint256 remaining = total - _offset;
        uint256 size = (_limit == 0 || _limit > remaining) ? remaining : _limit;

        // 构造返回数组
        nftIds = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            nftIds[i] = allNFTs[_offset + i];
        }

        return (nftIds, total);
    }

    /**
     * @dev 获取NFT的所有者/使用者
     * @param _nftId NFT ID
     * @return 所有者/使用者地址，如果NFT不存在则返回 address(0)
     *
     * 语义说明：
     * - 如果 nftUsed[_nftId] == false：返回当前拥有者
     * - 如果 nftUsed[_nftId] == true：返回使用者（NFT已使用，但保留使用者记录）
     *
     * 用途：
     * - 查询NFT当前拥有者
     * - 查询已使用NFT的使用者（追溯历史）
     * - O(1)时间复杂度，高效查询
     *
     * 示例：
     * ```
     * address owner = getNFTOwner(nftId);
     * bool used = nftUsed[nftId];
     * if (used) {
     *     // owner 是使用者
     * } else {
     *     // owner 是当前拥有者
     * }
     * ```
     */
    function getNFTOwner(uint256 _nftId) external view returns (address) {
        return nftOwner[_nftId];
    }

    /**
     * @dev 检查用户是否可以铸造NFT
     * @param _user 用户地址
     * @return canMint 是否可以铸造
     * @return burnedAmount 当前已销毁数量
     * @return required 需要销毁的数量
     *
     * 铸造条件：
     * 1. 用户已绑定NFT（至少使用过一次NFT销毁）
     * 2. 累计销毁数量达到要求（10000个代币）
     * 3. 满足条件后可以铸造任意数量的NFT
     */
    function canMintNFT(
        address _user
    )
        external
        view
        returns (bool canMint, uint256 burnedAmount, uint256 required)
    {
        burnedAmount = users[_user].burnedAmount;
        required = burnRequirementForNFT;

        // 检查是否达到销毁要求且已绑定NFT
        bool hasEnoughBurned = burnedAmount >= required;
        bool hasBound = users[_user].boundNFT != 0;

        return (hasBound && hasEnoughBurned, burnedAmount, required);
    }

    /**
     * @dev 获取用户完整信息（包括可提取代币等）
     * @param _user 用户地址
     * @return power 用户算力
     * @return burnedAmount 当前销毁计数
     * @return totalBurnedAmount 历史总销毁
     * @return boundNFT 用户绑定的NFT ID
     */
    function getUserFullInfo(
        address _user
    )
        external
        view
        returns (
            uint256 power,
            uint256 burnedAmount,
            uint256 totalBurnedAmount,
            uint256 boundNFT
        )
    {
        UserInfo storage info = users[_user];
        return (
            info.power,
            info.burnedAmount,
            info.totalBurnedAmount,
            info.boundNFT
        );
    }

    /**
     * @dev 获取用户的上下级关系
     * @param _user 用户地址
     * @return upline1 直接上级地址
     * @return upline2 二级上级地址
     */
    function getUserRelation(
        address _user
    ) external view returns (address upline1, address upline2) {
        return (users[_user].upline1, users[_user].upline2);
    }

    /**
     * @dev 获取用户的结算信息
     * @param _user 用户地址
     * @return lastSettleDay 最后结算到哪一天
     * @return powerHistoryLength 算力记录条数
     */
    function getUserSettleInfo(
        address _user
    )
        external
        view
        returns (uint256 lastSettleDay, uint256 powerHistoryLength)
    {
        UserInfo storage info = users[_user];
        return (info.lastSettleDay, info.powerHistory.size());
    }

    /**
     * @dev 获取用户的算力历史记录
     * @param _user 用户地址
     * @return dayList 天数数组
     * @return powerList 对应的算力数组
     */
    function getUserPowerHistory(
        address _user
    ) external view returns (uint256[] memory, uint256[] memory) {
        IterableMapping.Map storage history = users[_user].powerHistory;
        uint256 length = history.size();

        uint256[] memory dayList = new uint256[](length);
        uint256[] memory powerList = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 day = history.getKeyAtIndex(i);
            dayList[i] = day;
            powerList[i] = history.get(day);
        }

        return (dayList, powerList);
    }

    // ==================== 内部辅助函数 ====================

    /**
     * @dev 获取用户在指定天数的算力
     * @param userInfo 用户信息
     * @param _day 指定天数
     * @return 该天的算力
     *
     * 查询逻辑：
     * - 如果当天有记录，直接返回
     * - 否则利用 keys 数组的有序性，从后往前查找最近的算力记录
     */
    function _getUserPowerForDay(
        UserInfo storage userInfo,
        uint256 _day
    ) internal view returns (uint256) {
        // 如果当天有记录，直接返回
        uint256 power = userInfo.powerHistory.get(_day);
        if (power > 0) {
            return power;
        }

        // 如果没有任何算力记录，直接返回0
        uint256 keysLength = userInfo.powerHistory.size();
        if (keysLength == 0) {
            return 0;
        }

        // 获取第一次有算力的天数
        uint256 firstPowerDay = userInfo.powerHistory.getKeyAtIndex(0);

        // 如果查询日期在第一次有算力之前，返回0
        if (_day < firstPowerDay) {
            return 0;
        }

        // 计算最大查找天数：从查询日期到第一次有算力的天数，但不超过365天
        uint256 maxSearchDays = _day - firstPowerDay;
        if (maxSearchDays > 365) {
            maxSearchDays = 365;
        }

        // 向前查找最近的算力记录，循环不同天数消耗的gas为：
        // benchmark N=1 gasUsed=29621
        // benchmark N=10 gasUsed=51113
        // benchmark N=50 gasUsed=146633
        // benchmark N=365 gasUsed=898865
        for (uint256 i = 1; i <= maxSearchDays; i++) {
            power = userInfo.powerHistory.get(_day - i);
            if (power > 0) {
                return power;
            }
        }
        // 查不到
        // 利用 keys 数组的有序性，从后往前查找小于等于 _day 的最近记录
        for (uint256 i = keysLength; i > 0; i--) {
            uint256 recordDay = userInfo.powerHistory.getKeyAtIndex(i - 1);
            if (recordDay <= _day) {
                return userInfo.powerHistory.get(recordDay);
            }
        }

        return 0;
    }

    /**
     * @dev 计算用户在指定日期范围内的奖励
     * @param userInfo 用户信息
     * @param startDay 开始日期
     * @param endDay 结束日期
     * @return rewards 计算出的奖励金额
     *
     * 功能说明：
     * - 按天遍历计算每天的奖励
     * - 根据用户算力占比分配每日产币
     * - 纯计算函数，不修改状态
     */
    function _calculateRewards(
        UserInfo storage userInfo,
        uint256 startDay,
        uint256 endDay
    ) internal view returns (uint256) {
        // 确定开始计算的日期

        uint256 rewards = 0;
        // 初始值取前一日算力，如果没有记录则向前查找最近的记录
        uint256 currentPower = _getUserPowerForDay(userInfo, startDay - 1); //需要先获取startDay前一天的算力，因为userInfo.powerHistory可能没有startDay的算力记录

        for (uint256 day = startDay; day <= endDay; day++) {
            //检查当天是否有算力，有算力则更新currentPower，否则继续使用前一天的currentPower
            uint256 dayPower = userInfo.powerHistory.get(day);
            if (dayPower > 0) {
                currentPower = dayPower;
            }
            //无需else，如果dayPower为0，继续使用currentPower
            // else {
            //     currentPower = _getUserPowerForDay(userInfo, day);
            // }

            uint256 totalPowerForDay = _getTotalPowerForDay(day);

            if (totalPowerForDay > 0 && currentPower > 0) {
                uint256 dailyEmission = _getDailyEmission(day);
                uint256 dailyUserPool = (dailyEmission *
                    USER_ALLOCATION_PERCENT) / 100;
                uint256 userShare = (dailyUserPool * currentPower) /
                    totalPowerForDay;
                rewards += userShare;
            }
        }

        return rewards;
    }

    /**
     * @dev 计算销毁代币获得的算力
     * @param _burnAmount 销毁代币数量
     * @return 获得的算力
     *
     * 算力计算公式推导：
     * 设：销毁代币=B，新增算力=P，原总算力=T，188天用户总产币=D
     * 需求：新算力P在新总算力(T+P)下，188天产出B代币
     * 即：188天产出 = D * P/(T+P) = B
     * 推导：D*P = B*(T+P)
     *      D*P = B*T + B*P
     *      P*(D-B) = B*T
     *      P = B*T / (D-B)
     *
     * 注意：使用当前天的产币量计算，考虑了减半因素
     */
    function _calculatePowerFromBurn(
        uint256 _burnAmount
    ) internal view returns (uint256) {
        
        // 使用当前天的产币量（考虑减半）
        uint256 currentDayEmission = _getDailyEmission(_getCurrentDay());
        uint256 userDailyEmission = (currentDayEmission *
            USER_ALLOCATION_PERCENT) / 100;
        uint256 totalDaysOutput = userDailyEmission * powerCalculationDays;

        // 防止销毁量超过188天总产币（这种情况下公式会失效）
        require(
            _burnAmount < totalDaysOutput,
            "Burn amount exceeds 188 days emission"
        );

        // 新增算力 = 销毁代币 * 当前总算力 / (188天总产币 - 销毁代币)
        // 这样可以保证新算力在新的总算力下，188天能产出等量代币
        return (_burnAmount * totalPower) / (totalDaysOutput - _burnAmount);
    }

    /**
     * @dev 分配上级算力奖励
     * @param _user 用户地址
     * @param _newPower 新增算力
     *
     * 注意：使用用户级别的关系，而不是NFT级别的关系
     */
    function _distributeUplineRewards(
        address _user,
        uint256 _newPower
    ) internal {
        UserInfo storage userInfo = users[_user];

        // 给直接上级50%奖励
        if (userInfo.upline1 != address(0)) {
            uint256 upline1Bonus = (_newPower * UPLINE1_BONUS_PERCENT) / 100;
            // 新版solidity编译器会自动检查溢出，这里不需要手动检查
            // require(
            //     users[userInfo.upline1].power + upline1Bonus >=
            //         users[userInfo.upline1].power,
            //     "Power overflow"
            // );
            // require(
            //     totalPower + upline1Bonus >= totalPower,
            //     "Total power overflow"
            // );
            _updateUserPower(userInfo.upline1, upline1Bonus);
        }

        // 给二级上级25%奖励
        if (userInfo.upline2 != address(0)) {
            uint256 upline2Bonus = (_newPower * UPLINE2_BONUS_PERCENT) / 100;
            // 新版solidity编译器会自动检查溢出，这里不需要手动检查
            // require(
            //     users[userInfo.upline2].power + upline2Bonus >=
            //         users[userInfo.upline2].power,
            //     "Power overflow"
            // );
            // require(
            //     totalPower + upline2Bonus >= totalPower,
            //     "Total power overflow"
            // );
            _updateUserPower(userInfo.upline2, upline2Bonus);
        }
    }

    /**
     * @dev 更新用户NFT持有列表
     * @param _from 转出地址
     * @param _to 接收地址
     * @param _tokenId NFT ID
     *
     * Gas优化说明：
     * - 使用索引映射实现O(1)删除，避免循环遍历
     * - 使用swap-and-pop技术：将目标元素与最后一个元素交换，然后删除最后一个
     * - 删除操作从O(n)优化到O(1)，大幅降低gas消耗
     *
     * 安全检查：
     * - 防止数组下溢：检查长度非零
     * - 防止错误删除：验证NFT确实属于转出地址
     */
    function _updateUserNFTList(
        address _from,
        address _to,
        uint256 _tokenId
    ) internal {
        // 从转出用户列表中移除（O(1)操作）
        if (_from != address(0)) {
            uint256[] storage fromTokens = userNFTs[_from];
            uint256 length = fromTokens.length;

            // 安全检查：确保用户有NFT可转出
            require(length > 0, "No NFTs to transfer");

            uint256 index = nftIndexInUserList[_from][_tokenId];

            // 安全检查：验证NFT确实属于转出地址（防止错误删除）
            require(fromTokens[index] == _tokenId, "NFT not owned by from");

            uint256 lastIndex = length - 1;

            // 如果不是最后一个元素，将最后一个元素移到当前位置
            if (index != lastIndex) {
                uint256 lastTokenId = fromTokens[lastIndex];
                fromTokens[index] = lastTokenId;
                nftIndexInUserList[_from][lastTokenId] = index; // 更新被移动元素的索引
            }

            // 删除最后一个元素
            fromTokens.pop();
            delete nftIndexInUserList[_from][_tokenId]; // 清除索引记录
        }

        // 添加到接收用户列表并更新所有者（O(1)操作）
        if (_to != address(0)) {
            nftIndexInUserList[_to][_tokenId] = userNFTs[_to].length; // 记录新索引位置
            userNFTs[_to].push(_tokenId);
            nftOwner[_tokenId] = _to; // 更新NFT所有者，用于O(1)查询
        }
    }

    //更新用户算力
    /**
     * @dev 更新用户算力
     * @param _user 用户地址
     * @param _addedPower 新增算力
     */
    function _updateUserPower(address _user, uint256 _addedPower) internal {
        users[_user].power += _addedPower;
        totalPower += _addedPower;
        _recordDailyPower(_user);
    }

    /**
     * @dev 记录用户每日算力变化
     * @param _user 用户地址
     *
     * 优化说明：
     * - 用户算力使用 IterableMapping 存储，day => power
     * - 自动处理新增和更新，代码更简洁
     * - 总算力继续使用 IterableMapping，便于全局查询
     */
    function _recordDailyPower(address _user) internal {
        uint256 today = _getCurrentDay();
        UserInfo storage userInfo = users[_user];

        // 记录用户算力变化（自动处理新增和更新）
        userInfo.powerHistory.set(today, userInfo.power);

        // 记录总算力
        dailyTotalPower.set(today, totalPower);

        // 记录第一个有数据的天数（仅在首次记录时， 初始化firstDataDay在初始化函数中
        // if (firstDataDay == 0) {
        //     firstDataDay = today;
        // }

    }

    /**
     * @dev 计算指定天数的总产币量
     * @param _day 指定的日期
     * @return 该天的总产币量
     */
    function _getDailyEmission(uint256 _day) internal view returns (uint256) {
        return dateEmission[_day];
    }

    /**
     * @dev 获取指定日期的总算力
     * @param _day 指定日期
     * @return 该日期的总算力
     */
    function _getTotalPowerForDay(
        uint256 _day
    ) internal view returns (uint256) {
        // 如果查询日期在系统启动之前，直接返回0
        if (firstDataDay > 0 && _day < firstDataDay) {
            return 0;
        }
        uint256 totalPowerForDay = dailyTotalPower.get(_day);
        return totalPowerForDay;
    }

    /**
     * @dev 记录节点奖励到总奖励池
     * @param _nodeAmount 节点奖励总额（大节点20% + 小节点5% 的总和）
     */
    function _recordNodeRewards(uint256 _nodeAmount) internal {
        // 直接累加到总奖励池，由各个席位按规则提取
        totalNodeRewards += _nodeAmount;
    }

    /**
     * @dev 检查圣诞方程式是否激活
     * @return 是否激活
     *
     * 激活条件：
     * 1. 管理员手动激活（christmasFormula.active == true）
     * 2. 或者自动激活：每年12月25日到次年1月5日（总共21天）
     */
    function _isChristmasFormulaActive() internal view returns (bool) {
        // 管理员手动激活
        if (christmasFormula.active) {
            return true;
        }

        // 自动激活：每年12月25日到次年1月5日
        (, uint month, uint day) = daysToDate(block.timestamp);
        return (month == 12 && day >= 25) || (month == 1 && day <= 5);
    }

    /**
     * @dev 计算用户在圣诞活动中应该销毁的固定数量
     * @param _user 用户地址
     * @param _receivedAmount 本次接收的金额，用于减去合约中的balance，来修正合约接收前的余额
     * @return 用户应销毁的代币数量
     *
     * 计算公式：用户算力 * 销毁因子
     * 销毁因子 = 流通代币的节点总分配比例 / 总算力
     * 流通代币 = 合约余额 + 用户提取总额 - 销毁总量
     */
    function _calculateChristmasBurnAmount(
        address _user,
        uint256 _receivedAmount
    ) internal view returns (uint256) {
        if (totalPower == 0 || users[_user].power == 0) {
            return 0;
        }

        // 动态计算流通代币数量（防止下溢出）// TODO 这里的逻辑需要测试
        uint256 totalSupply = address(this).balance +
            totalClaimed - _receivedAmount;

        // 如果销毁总量大于总供应量，说明没有流通代币
        if (totalBurnedTokens >= totalSupply) {
            return 0;
        }

        uint256 circulatingTokens = totalSupply - totalBurnedTokens;

        // 直接计算用户应销毁数量，避免精度损失
        // 公式：(用户算力 * 流通代币 * 节点总分配比例) / 总算力
        return
            (users[_user].power * circulatingTokens * NODE_ALLOCATION_PERCENT) /
            (totalPower * 100);
    }

    /**
     * @dev 获取当前天数（基于区块时间戳）
     * @return 从1970年1月1日到现在的天数
     */
    function _getCurrentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /**
     * @dev 更新每日数据
     */
    function _updateDailyData() internal {
        uint256 today = _getCurrentDay();
        if (today > currentDay) {
            currentDay = today;
        }
    }

    // ==================== 管理员功能 ====================

    /**
     * @dev 设置NFT合约地址
     * @param _nftContract NFT合约地址
     */
    function setNFTContract(address _nftContract) external onlyOwner {
        require(
            _nftContract != address(0),
            "NFT contract address cannot be zero"
        );
        nftContract = IPowerNFT(_nftContract);
    }

    /**
     * @dev 管理员手动激活圣诞方程式活动
     *
     * 激活后，不论是否在活动日期（12月25日-1月5日）中，都视为激活状态
     * 如果设置为false，则按日期自动激活（每年12月25日-1月5日）
     */
    function activateChristmasFormula() external onlyOwner {
        if (christmasFormula.active) {
            return;
        }
        christmasFormula.active = true;
        christmasFormula.level++;
        emit ChristmasFormulaUpdated(
            christmasFormula.startYear,
            christmasFormula.level,
            christmasFormula.active
        );
    }

    /**
     * @dev 管理员停用圣诞方程式活动
     *
     * 停用后，活动将按日期自动激活（每年12月25日-1月5日）
     * 如果设置为true，则强制激活，不受日期限制
     */
    function deactivateChristmasFormula() external onlyOwner {
        christmasFormula.active = false;
    }

    /**
     * @dev 设置系统参数
     * @param _parameter 参数名称
     * @param _value 新值
     */
    function setSystemParameter(
        string calldata _parameter,
        uint256 _value
    ) external onlyOwner {
        bytes32 paramHash = keccak256(abi.encodePacked(_parameter));
        uint256 oldValue;

        if (paramHash == keccak256("burnRequirementForNFT")) {
            oldValue = burnRequirementForNFT;
            burnRequirementForNFT = _value;
        } else if (paramHash == keccak256("powerCalculationDays")) {
            require(_value > 0 && _value <= 365, "Invalid day range");
            oldValue = powerCalculationDays;
            powerCalculationDays = _value;
        } else if (paramHash == keccak256("maxClaimDays")) {
            require(_value > 0 && _value <= 365, "Invalid max claim days");
            oldValue = maxClaimDays;
            maxClaimDays = _value;
        } else {
            revert("Unknown parameter");
        }

        emit SystemParameterUpdated(_parameter, oldValue, _value);
    }

    /**
     * @dev 暂停合约
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev 恢复合约
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev 启动系统（仅限所有者，只能调用一次）
     *
     * 功能说明：
     * - 启动后，空投功能（batchMakeRelationAndInitPowerByOperator）将不可用
     * - 启动后，正式业务功能（burn, mint, claim等）将可用
     * - 此操作不可逆，一旦启动无法回退到空投阶段
     */
    function start() external onlyOwner {
        require(!started, "System already started");
        started = true;
        emit SystemStarted();
    }

    /**
     * @dev 批量设置节点席位的提币地址
     * @param _seatIndexes 席位索引数组（0-NODE_SEATS-1）
     * @param _withdrawAddresses 提币地址数组
     */
    function setNodeWithdrawAddresses(
        uint256[] calldata _seatIndexes,
        address[] calldata _withdrawAddresses
    ) external onlyOwner {
        require(
            _seatIndexes.length == _withdrawAddresses.length,
            "Invalid array length"
        );

        for (uint256 i = 0; i < _seatIndexes.length; i++) {
            uint256 seatIndex = _seatIndexes[i];
            address withdrawAddress = _withdrawAddresses[i];

            require(seatIndex < NODE_SEATS, "Invalid seat index");
            require(
                withdrawAddress != address(0),
                "Withdraw address cannot be zero"
            );

            nodeWithdrawAddress[seatIndex] = withdrawAddress;

            emit NodeAdminUpdated(seatIndex, withdrawAddress);
        }
    }

    /**
     * @dev 节点席位提取奖励
     * @param _seatIndex 席位索引（0 - NODE_SEATS-1）
     *
     * 功能说明：
     * - 只有对应席位的提币地址可以调用
     * - 大节点席位：应得总额 = (totalNodeRewards * 20 / 25) / BIG_NODE_SEATS
     * - 小节点席位：应得总额 = (totalNodeRewards - totalNodeRewards * 20 / 25) / SMALL_NODE_SEATS
     * - 可提取额 = 应得总额 - 已提取额
     * - 提取后更新已提取额度
     */
    function claimNodeRewards(
        uint256 _seatIndex
    ) external nonReentrant whenNotPaused whenStarted {
        // 验证席位索引
        require(_seatIndex < NODE_SEATS, "Invalid seat index");

        // 验证调用者是该席位的提币地址
        address withdrawAddress = nodeWithdrawAddress[_seatIndex];
        require(withdrawAddress != address(0), "Withdraw address not set");
        require(
            withdrawAddress == msg.sender,
            "Not the withdraw address for this seat"
        );

        // 计算该席位应得总额（按席位类型等分）
        uint256 totalShare;
        if (_seatIndex < BIG_NODE_SEATS) {
            uint256 bigNodeRewards = (totalNodeRewards *
                BIG_NODE_ALLOCATION_PERCENT) / NODE_ALLOCATION_PERCENT;
            totalShare = bigNodeRewards / BIG_NODE_SEATS;
        } else {
            uint256 smallNodeRewards = (totalNodeRewards *
                SMALL_NODE_ALLOCATION_PERCENT) / NODE_ALLOCATION_PERCENT;
            totalShare = smallNodeRewards / SMALL_NODE_SEATS;
        }

        // 计算可提取额度
        uint256 alreadyWithdrawn = nodeWithdrawn[_seatIndex];
        require(totalShare > alreadyWithdrawn, "No rewards to claim");

        uint256 claimableAmount = totalShare - alreadyWithdrawn;
        require(claimableAmount > 0, "No rewards to claim");
        require(
            address(this).balance >= claimableAmount,
            "Insufficient contract balance"
        );

        // 更新已提取额度
        nodeWithdrawn[_seatIndex] = totalShare;
        totalClaimed += claimableAmount;
        // 转账原生币
        (bool success, ) = msg.sender.call{value: claimableAmount}("");
        require(success, "Transfer failed");

        emit NodeRewardClaimed(msg.sender, claimableAmount);
    }

    /**
     * @dev 查询节点席位可提取奖励
     * @param _seatIndex 席位索引（0-NODE_SEATS-1）
     * @return 可提取奖励金额
     */
    function getNodeSeatClaimable(
        uint256 _seatIndex
    ) external view returns (uint256) {
        require(_seatIndex < NODE_SEATS, "Invalid seat index");

        // 计算该席位应得总额
        uint256 totalShare;
        if (_seatIndex < BIG_NODE_SEATS) {
            uint256 bigNodeRewards = (totalNodeRewards *
                BIG_NODE_ALLOCATION_PERCENT) / NODE_ALLOCATION_PERCENT;
            totalShare = bigNodeRewards / BIG_NODE_SEATS;
        } else {
            uint256 smallNodeRewards = (totalNodeRewards *
                SMALL_NODE_ALLOCATION_PERCENT) / NODE_ALLOCATION_PERCENT;            
            totalShare = smallNodeRewards / SMALL_NODE_SEATS;
        }
        
        // 计算可提取额度
        uint256 alreadyWithdrawn = nodeWithdrawn[_seatIndex];

        if (totalShare > alreadyWithdrawn) {
            return totalShare - alreadyWithdrawn;
        }

        return 0;
    }

    /**
     * @dev 获取所有节点席位的提币地址
     * @return 提币地址数组
     */
    function getNodeWithdrawAddresses()
        external
        view
        returns (address[] memory)
    {
        address[] memory addresses = new address[](NODE_SEATS);
        for (uint256 i = 0; i < NODE_SEATS; i++) {
            addresses[i] = nodeWithdrawAddress[i];
        }
        return addresses;
    }

    /**
     * @dev 获取节点席位的详细信息
     * @param _seatIndex 席位索引（0-NODE_SEATS-1）
     * @return withdrawAddress 提币地址
     * @return totalShare 应得总额
     * @return withdrawn 已提取额
     * @return claimable 可提取额
     */
    function getNodeSeatInfo(
        uint256 _seatIndex
    )
        external
        view
        returns (
            address withdrawAddress,
            uint256 totalShare,
            uint256 withdrawn,
            uint256 claimable
        )
    {
        require(_seatIndex < NODE_SEATS, "Invalid seat index");

        withdrawAddress = nodeWithdrawAddress[_seatIndex];

        if (_seatIndex < BIG_NODE_SEATS) {
            uint256 bigNodeRewards = (totalNodeRewards *
                BIG_NODE_ALLOCATION_PERCENT) / NODE_ALLOCATION_PERCENT;
            totalShare = bigNodeRewards / BIG_NODE_SEATS;
        } else {
            uint256 smallNodeRewards = (totalNodeRewards *
                SMALL_NODE_ALLOCATION_PERCENT) / NODE_ALLOCATION_PERCENT;            
            totalShare = smallNodeRewards / SMALL_NODE_SEATS;
        }

        withdrawn = nodeWithdrawn[_seatIndex];
        claimable = totalShare > withdrawn ? totalShare - withdrawn : 0;

        return (withdrawAddress, totalShare, withdrawn, claimable);
    }

    // ==================== 操作员管理 ====================

    /**
     * @dev 设置操作员地址（仅限所有者）
     * @param _operator 新的操作员地址
     *
     * 功能说明：
     * - 操作员可以给任意地址添加算力
     * - 只有合约所有者可以设置/更改操作员
     * - 设置为零地址可以移除操作员权限
     *
     * 注意事项：
     * - 操作员权限较大，请谨慎设置
     * - 建议定期更换操作员地址
     */
    function setOperator(address _operator) external onlyOwner {
        address oldOperator = operator;
        operator = _operator;
        emit OperatorUpdated(oldOperator, _operator);
    }

    /**
     * @dev 操作员添加算力到指定地址
     * @param _user 接收算力的用户地址
     * @param _powerAmount 要添加的算力数量
     *
     * 功能说明：
     * - 只有操作员可以调用此函数
     * - 可以给任意地址添加算力
     * - 会更新用户的算力历史记录
     * - 会更新全网总算力
     * - 会分配上级奖励（如果用户有上级关系）
     *
     * 参数限制：
     * - 用户地址不能为零地址
     * - 算力数量必须大于0
     * - 添加后不能导致溢出
     *
     * 注意事项：
     * - 此操作会触发每日数据更新
     * - 会自动记录算力历史
     * - 会触发上级奖励分配
     */
    function addPowerByOperator(
        address _user,
        uint256 _powerAmount
    )
        external
        onlyOperator
        whenNotPaused
        whenStarted
        nonReentrant
        updateDaily
        checkSystemLimits
    {
        require(_user != address(0), "User address cannot be zero");
        require(_powerAmount > 0, "Power amount must be greater than 0");

        // 更新用户算力
        _updateUserPower(_user, _powerAmount);

        emit PowerAddedByOperator(
            msg.sender,
            _user,
            _powerAmount,
            users[_user].power,
            totalPower
        );
        emit PowerUpdated(_user, users[_user].power, totalPower);
    }

    /**
     * @dev 查询当前操作员地址
     * @return 操作员地址
     */
    function getOperator() external view returns (address) {
        return operator;
    }

    // ==================== 版本管理 ====================

    /**
     * @dev 获取合约版本号
     * @return 当前合约的版本号
     *
     * 用途：
     * - 前端可以根据版本号显示不同的功能
     * - 用于追踪合约升级历史
     * - 帮助判断合约是否需要升级
     */
    function getVersion() external view returns (uint256) {
        return version;
    }

    /**
     * @dev 检查合约是否可以升级到指定版本
     * @param _newVersion 目标版本号
     * @return 是否可以升级
     *
     * 规则：
     * - 新版本号必须大于当前版本
     * - 用于升级前的验证
     */
    function canUpgradeTo(uint256 _newVersion) external view returns (bool) {
        return _newVersion > version;
    }

    /**
     * @dev 获取总算力历史记录的天数
     * @return 记录的天数数量
     *
     * 用途：
     * - 统计系统运行时长
     * - 数据分析和监控
     */
    function getTotalPowerDaysCount() external view returns (uint256) {
        return dailyTotalPower.size();
    }

    /**
     * @dev 获取总算力历史记录
     * @return 日期数组
     * @return 对应的总算力数组
     *
     * 用途：
     * - 用于外部测试和验证奖励计算
     * - 提供历史总算力数据
     */
    function getDailyTotalPowerHistory()
        external
        view
        returns (uint256[] memory, uint256[] memory)
    {
        uint256 size = dailyTotalPower.size();
        uint256[] memory daysList = new uint256[](size);
        uint256[] memory powersList = new uint256[](size);

        for (uint256 i = 0; i < size; i++) {
            daysList[i] = dailyTotalPower.getKeyAtIndex(i);
            powersList[i] = dailyTotalPower.get(daysList[i]);
        }

        return (daysList, powersList);
    }

    /**
     * @dev 预留存储空间，用于未来版本升级时添加新的状态变量
     *
     * 重要性：
     * - Solidity合约的存储布局是固定的
     * - 升级时添加新变量可能覆盖已有数据
     * - __gap预留了50个uint256的空间
     * - 添加新变量时，从__gap中"借用"空间
     *
     * 使用方法：
     * ```solidity
     * uint256 public newVariable;  // 占用1个slot
     * uint256[49] private __gap;   // 减少到49个slot
     * ```
     *
     * 计算规则：
     * - 每添加一个uint256变量，__gap减少1
     * - 每添加一个address变量，__gap减少1（address占20字节）
     * - struct、mapping、array等复杂类型也占用空间
     * - 总空间保持不变，确保存储布局兼容
     *
     * 注意事项：
     * - 不要修改__gap的位置
     * - 不要删除__gap
     * - 升级时要谨慎计算占用的空间
     * - 使用OpenZeppelin的升级插件验证存储布局
     *
     * 当前使用情况：
     * - operator (address): 占用1个slot
     * - nftBoundTo (mapping): 占用1个slot
     * - nodeWithdrawAddress (mapping): 占用1个slot
     * - started (bool): 占用1个slot
     * - 剩余空间: 46个slot
     */
    uint256[46] private __gap;
}
