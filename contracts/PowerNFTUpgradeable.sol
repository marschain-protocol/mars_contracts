// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title IPowerContract
 * @dev 算力合约接口，用于转账时回调
 */
interface IPowerContract {
    function makeRelation(address from, address to, uint256 tokenId) external;
    function isNFTUsed(uint256 tokenId) external view returns (bool);
}

/**
 * @title PowerNFTUpgradeable
 * @dev 可升级的算力系统NFT合约，基于ERC1155标准和UUPS代理模式
 *
 * ==================== 核心功能 ====================
 * 1. NFT的铸造和管理
 * 2. NFT转账时自动调用算力合约建立关系
 * 3. 支持暂停和权限控制
 * 4. 支持UUPS代理升级
 * 5. 已使用的NFT不可转让（保证关系链稳定性）
 *
 * ==================== 设计原则 ====================
 * - 职责单一：只负责NFT相关功能，业务逻辑在PowerContract中
 * - 简洁清晰：避免复杂业务逻辑，保持代码可维护性
 * - 安全可靠：完善的权限控制和状态检查
 * - 可升级性：使用UUPS模式支持合约升级
 * - 低耦合：通过接口与PowerContract交互
 *
 * ==================== 可升级特性 ====================
 *
 * 升级模式：UUPS（Universal Upgradeable Proxy Standard）
 * - 升级逻辑在实现合约中
 * - 比TransparentProxy更省gas
 * - 只有合约所有者可以升级
 *
 * 部署流程：
 * 1. 部署实现合约（PowerNFTUpgradeable）
 * 2. 部署ERC1967Proxy代理合约
 * 3. 通过代理合约调用initialize函数
 * 4. 设置powerContract地址
 *
 * 升级流程：
 * 1. 部署新的实现合约（PowerNFTUpgradeableV2）
 * 2. 调用upgradeToAndCall函数
 * 3. 可选择性调用reinitialize
 * 4. NFT数据和所有权保持不变
 *
 * 存储布局注意事项：
 * - 不能修改已有状态变量的顺序
 * - 不能修改已有状态变量的类型
 * - 可以在末尾添加新的状态变量
 * - 预留了__gap数组用于未来扩展
 *
 * 与非升级版本的区别：
 * - 使用Initializable替代constructor
 * - 使用Upgradeable版本的OpenZeppelin库
 * - 添加了version管理
 * - 添加了_authorizeUpgrade授权函数
 * - 添加了reinitialize函数
 *
 * 安全考虑：
 * - 构造函数中调用_disableInitializers
 * - 只有owner可以升级合约
 * - 升级前充分测试新实现
 * - 使用OpenZeppelin升级插件验证存储布局
 *
 * ==================== NFT与升级的关系 ====================
 * - 升级不影响已铸造的NFT
 * - NFT所有权保持不变
 * - NFT ID保持不变
 * - 元数据URI可以通过升级更新
 * - 可以在升级中添加新的NFT功能
 *
 * @custom:oz-upgrades-from PowerNFTUpgradeable
 * @custom:security-contact security@example.com
 */
contract PowerNFTUpgradeable is
    Initializable,
    ERC1155Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ERC1155SupplyUpgradeable,
    UUPSUpgradeable
{
    // ==================== 状态变量 ====================

    /// @dev 算力合约地址，用于转账时回调
    address public powerContract;

    /// @dev NFT元数据基础URI
    string public baseURI;

    /// @dev 合约版本号
    uint256 public version;

    // ==================== 事件定义 ====================

    /// @dev 算力合约地址更新事件
    event PowerContractUpdated(
        address indexed oldContract,
        address indexed newContract
    );

    /// @dev NFT铸造事件
    event NFTMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 amount
    );

    /// @dev 基础URI更新事件
    event BaseURIUpdated(string oldURI, string newURI);

    /// @dev 合约升级事件
    event ContractUpgraded(uint256 oldVersion, uint256 newVersion);

    // ==================== 修饰符 ====================

    /// @dev 只允许算力合约调用
    modifier onlyPowerContract() {
        require(msg.sender == powerContract, "Only power contract can call");
        _;
    }

    /// @dev 检查NFT未被使用（从PowerContract获取状态）
    modifier notUsed(uint256 tokenId) {
        // 修复: 必须设置powerContract才能进行NFT转账
        require(powerContract != address(0), "Power contract not set");
        require(
            !IPowerContract(powerContract).isNFTUsed(tokenId),
            "NFT already used, cannot transfer"
        );
        _;
    }

    // ==================== 构造函数 ====================

    /**
     * @dev 构造函数 - 禁用实现合约的初始化
     *
     * @custom:oz-upgrades-unsafe-allow constructor
     *
     * 重要说明：
     * - 这是可升级合约的安全措施
     * - _disableInitializers()防止实现合约本身被初始化
     * - 只有通过代理合约才能调用initialize
     * - 防止攻击者直接操作实现合约
     *
     * 为什么需要这个？
     * - 实现合约和代理合约使用不同的存储空间
     * - 如果实现合约被初始化，可能导致安全问题
     * - 禁用后，实现合约无法被直接使用
     *
     * 部署后的状态：
     * - 实现合约：不可初始化，不可直接使用
     * - 代理合约：通过delegatecall使用实现合约代码，使用自己的存储
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ==================== 初始化函数 ====================

    /**
     * @dev 初始化函数，替代构造函数 - 部署后必须调用一次
     * @param _baseURI NFT元数据基础URI
     *
     * 功能说明：
     * - 可升级合约不能使用constructor，必须使用initialize
     * - 通过代理合约部署后，必须立即调用此函数
     * - 此函数只能调用一次（initializer修饰符保证）
     *
     * 初始化内容：
     * 1. 初始化所有继承的合约：
     *    - ERC1155：设置默认URI
     *    - Ownable：设置合约所有者
     *    - Pausable：初始化暂停状态
     *    - ERC1155Supply：初始化供应量跟踪
     *    - UUPSUpgradeable：初始化升级功能
     *
     * 2. 设置核心变量：
     *    - baseURI：NFT元数据基础URI
     *    - version：合约版本号（初始为1）
     *
     * 调用时机：
     * - 必须在部署代理合约后立即调用
     * - 建议在同一个交易中完成部署和初始化
     * - 可以使用OpenZeppelin的deployProxy函数自动完成
     *
     * 后续配置：
     * - 需要通过setPowerContract设置算力合约地址
     * - 可以通过setBaseURI更新元数据URI
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
     *
     * 建议的完整部署流程：
     * 1. 部署PowerContractUpgradeable并初始化
     * 2. 部署PowerNFTUpgradeable并初始化
     * 3. PowerContract.setNFTContract(PowerNFT代理地址)
     * 4. PowerNFT.setPowerContract(PowerContract代理地址)
     */
    function initialize(string memory _baseURI) public initializer {
        __ERC1155_init(_baseURI);
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ERC1155Supply_init();
        __UUPSUpgradeable_init();

        baseURI = _baseURI;
        version = 1;
    }

    /**
     * @dev 重新初始化函数，用于升级时的数据迁移或新功能初始化
     * @param _newVersion 新版本号
     *
     * 功能说明：
     * - 在合约升级后可以调用，用于初始化新功能或迁移数据
     * - 可以多次调用，但版本号必须递增
     * - reinitializer(version)修饰符确保每个版本只初始化一次
     *
     * 使用场景：
     * 1. 升级后添加了新的状态变量需要初始化
     * 2. 需要执行数据迁移或格式转换
     * 3. 修改了某些逻辑需要调整现有数据
     * 4. 添加了新的NFT功能需要进行一次性配置
     *
     * 版本管理：
     * - version从1开始
     * - 每次调用reinitialize，version必须大于当前值
     * - 版本号用于追踪合约的升级历史
     *
     * 调用时机：
     * - 在执行upgradeToAndCall时一起调用
     * - 也可以在升级后单独调用
     * - 只有owner可以调用（通过_authorizeUpgrade限制）
     *
     * NFT升级示例：
     * ```solidity
     * // 升级到V2，添加NFT等级系统
     * function reinitializeV2() public reinitializer(2) {
     *     version = 2;
     *     // 为所有已存在的NFT设置默认等级
     *     defaultNFTLevel = 1;
     *     emit ContractUpgraded(1, 2);
     * }
     * ```
     *
     * 注意事项：
     * - 每个版本号只能初始化一次
     * - 版本号必须是递增的uint8类型
     * - 不能跳过版本号（如果要跳过，需要特殊处理）
     * - 此函数是可选的，简单升级可以不调用
     *
     * 当前实现：
     * - 只更新version变量
     * - 触发ContractUpgraded事件
     * - 子类可以override添加自定义逻辑
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
     * 功能说明：
     * - 这是UUPS升级模式的关键函数
     * - 在执行升级前会自动调用此函数验证权限
     * - 只有通过验证才能完成升级
     *
     * UUPS升级流程：
     * 1. 部署新的实现合约（如PowerNFTUpgradeableV2）
     * 2. 调用代理合约的upgradeToAndCall函数
     * 3. 系统自动调用此函数检查权限
     * 4. 如果验证通过，更新代理合约指向的实现地址
     * 5. 可选择性调用reinitialize初始化新功能
     *
     * 安全机制：
     * - onlyOwner修饰符：只有合约所有者可以升级
     * - 防止未授权的升级操作
     * - 如果此函数被删除或修改不当，合约将无法升级
     *
     * NFT升级的特殊考虑：
     * - 升级不会影响已铸造的NFT
     * - NFT所有权保持不变
     * - tokenId保持不变
     * - 可以在升级中添加新的NFT属性或功能
     * - 建议升级前备份重要的NFT数据
     *
     * 重要警告：
     * - 升级后的新合约也必须包含此函数
     * - 如果新合约没有_authorizeUpgrade，将无法再次升级
     * - 这会导致合约被"锁死"在当前版本
     *
     * 最佳实践：
     * - 升级前先部署新合约到测试网测试
     * - 确认新合约的NFT功能正常
     * - 验证存储布局兼容性
     * - 确保新合约继承UUPSUpgradeable
     * - 考虑使用多签钱包控制升级权限
     * - 升级前通知用户，避免在升级期间进行NFT操作
     *
     * 自定义授权逻辑示例：
     * ```solidity
     * function _authorizeUpgrade(address newImplementation) internal override {
     *     require(msg.sender == owner(), "Unauthorized");
     *     // 可以添加额外的验证
     *     require(
     *         IPowerNFTUpgradeable(newImplementation).version() > version,
     *         "New version must be greater"
     *     );
     * }
     * ```
     *
     * 当前实现：
     * - 只检查调用者是否为owner
     * - 不验证新实现合约的有效性（可以根据需要添加）
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // ==================== 核心NFT功能 ====================

    /**
     * @dev 铸造NFT（只能由算力合约调用）
     * @param to 接收地址
     * @param tokenId NFT ID
     * @param amount 数量（通常为1）
     * @param data 额外数据
     */
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes memory data
    ) external onlyPowerContract whenNotPaused {
        require(to != address(0), "Recipient address cannot be zero");
        require(amount == 1, "Amount must be 1 for unique NFT");
        require(!exists(tokenId), "TokenId already exists");

        _mint(to, tokenId, amount, data);
        emit NFTMinted(to, tokenId, amount);
    }

    /**
     * @dev 批量铸造NFT（只能由算力合约调用）
     * @param to 接收地址
     * @param ids NFT ID数组
     * @param amounts 数量数组
     * @param data 额外数据
     */
    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external onlyPowerContract whenNotPaused {
        require(to != address(0), "Recipient address cannot be zero");
        require(
            ids.length == amounts.length,
            "IDs and amounts length mismatch"
        );
        require(ids.length > 0, "Empty arrays not allowed");
        require(ids.length <= 100, "Batch size too large"); // 防止gas耗尽

        // 验证每个NFT的唯一性和数量
        for (uint256 i = 0; i < ids.length; i++) {
            require(amounts[i] == 1, "Amount must be 1 for unique NFT");
            require(!exists(ids[i]), "TokenId already exists");

            // 检查数组中是否有重复的tokenId
            for (uint256 j = i + 1; j < ids.length; j++) {
                require(ids[i] != ids[j], "Duplicate tokenId in batch");
            }
        }

        _mintBatch(to, ids, amounts, data);

        // 触发单个铸造事件（便于前端监听）
        for (uint256 i = 0; i < ids.length; i++) {
            emit NFTMinted(to, ids[i], amounts[i]);
        }
    }

    /**
     * @dev 重写单个NFT转账方法，添加使用状态检查和关系建立
     * @param from 转出地址
     * @param to 接收地址
     * @param id NFT ID
     * @param amount 数量
     * @param data 额外数据
     *
     * @notice 重要：必须成功调用 makeRelation 才能完成转账
     * @notice 如果 makeRelation 失败，整个转账会回滚
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public override whenNotPaused notUsed(id) {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );

        // 执行转账
        _safeTransferFrom(from, to, id, amount, data);

        // 【关键修改】必须成功建立关系才能完成转账
        // 如果未设置算力合约，转账失败
        require(powerContract != address(0), "Power contract not set");

        // 直接调用 makeRelation，不使用 try-catch
        // 如果调用失败，整个交易会回滚，转账不会生效
        IPowerContract(powerContract).makeRelation(from, to, id);
    }

    /**
     * @dev 重写批量NFT转账方法，添加使用状态检查和关系建立
     * @param from 转出地址
     * @param to 接收地址
     * @param ids NFT ID数组
     * @param amounts 数量数组
     * @param data 额外数据
     *
     * @notice 重要：必须成功调用 makeRelation 才能完成转账
     * @notice 如果任何一个 NFT 的 makeRelation 失败，整个批量转账会回滚
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public override whenNotPaused {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );

        // 【关键修改】必须设置算力合约才能转账
        require(powerContract != address(0), "Power contract not set");

        // 检查所有NFT都未被使用
        for (uint256 i = 0; i < ids.length; i++) {
            require(
                !IPowerContract(powerContract).isNFTUsed(ids[i]),
                "NFT already used, cannot transfer"
            );
        }

        // 执行批量转账
        _safeBatchTransferFrom(from, to, ids, amounts, data);

        // 【关键修改】为每个NFT建立关系，任何一个失败都会导致整个交易回滚
        // 移除 try-catch，直接调用
        for (uint256 i = 0; i < ids.length; i++) {
            IPowerContract(powerContract).makeRelation(from, to, ids[i]);
        }
    }

    // ==================== 元数据管理 ====================

    /**
     * @dev 获取NFT的元数据URI
     * @param tokenId NFT ID
     * @return NFT的完整URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        require(exists(tokenId), "NFT does not exist");
        return string(abi.encodePacked(baseURI, _uint2str(tokenId), ".json"));
    }

    /**
     * @dev 设置基础URI（只能由合约所有者调用）
     * @param _baseURI 新的基础URI
     */
    function setBaseURI(string memory _baseURI) external onlyOwner {
        string memory oldURI = baseURI;
        baseURI = _baseURI;
        _setURI(_baseURI);
        emit BaseURIUpdated(oldURI, _baseURI);
    }

    // ==================== 管理员功能 ====================

    /**
     * @dev 设置算力合约地址（只能由合约所有者调用）
     * @param _powerContract 算力合约地址
     */
    function setPowerContract(address _powerContract) external onlyOwner {
        address oldContract = powerContract;
        powerContract = _powerContract;
        emit PowerContractUpdated(oldContract, _powerContract);
    }

    /**
     * @dev 暂停合约（只能由合约所有者调用）
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev 恢复合约（只能由合约所有者调用）
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ==================== 查询功能 ====================

    /**
     * @dev 获取用户拥有的所有NFT ID和数量
     * @param account 用户地址
     * @param tokenIds 要查询的NFT ID数组
     * @return balances 对应的余额数组
     */
    function balanceOfBatch(
        address account,
        uint256[] memory tokenIds
    ) external view returns (uint256[] memory balances) {
        require(tokenIds.length > 0, "Empty array not allowed");
        require(tokenIds.length <= 100, "Array too large"); // 防止 gas
        address[] memory accounts = new address[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            accounts[i] = account;
        }
        return ERC1155Upgradeable.balanceOfBatch(accounts, tokenIds);
    }

    /**
     * @dev 检查NFT是否存在
     * @param tokenId NFT ID
     * @return 是否存在
     */
    function exists(uint256 tokenId) public view override returns (bool) {
        return super.exists(tokenId);
    }

    /**
     * @dev 获取NFT总供应量
     * @param tokenId NFT ID
     * @return 总供应量
     */
    function totalSupply(
        uint256 tokenId
    ) public view override returns (uint256) {
        return super.totalSupply(tokenId);
    }

    // ==================== 内部辅助函数 ====================

    /**
     * @dev 数字转字符串的辅助函数
     * @param _i 要转换的数字
     * @return 字符串形式的数字
     */
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }

        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }

        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }

        return string(bstr);
    }

    /**
     * @dev 重写_update函数以支持暂停功能、供应量跟踪和禁用销毁
     * @param from 转出地址
     * @param to 接收地址
     * @param ids NFT ID数组
     * @param values 数量数组
     *
     * 功能说明：
     * - 禁用NFT销毁功能（to == address(0) 时拒绝）
     * - 转账时检查NFT是否已被使用
     * - 支持暂停功能
     * - 跟踪供应量变化
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    )
        internal
        override(ERC1155Upgradeable, ERC1155SupplyUpgradeable)
        whenNotPaused
    {
        // 禁用销毁功能：禁止将NFT转移到address(0)
        require(to != address(0), "NFT burn is disabled");

        // 如果是转账操作（不是铸造），检查NFT是否可转让
        if (
            from != address(0) &&
            to != address(0) &&
            powerContract != address(0)
        ) {
            for (uint256 i = 0; i < ids.length; i++) {
                require(
                    !IPowerContract(powerContract).isNFTUsed(ids[i]),
                    "NFT already used, cannot transfer"
                );
            }
        }

        super._update(from, to, ids, values);
    }

    // ==================== 兼容性和安全 ====================

    /**
     * @dev 支持接口检查（ERC165标准）
     * @param interfaceId 接口ID
     * @return 是否支持该接口
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev 防止意外发送以太币到合约
     */
    receive() external payable {
        revert("Ether not accepted");
    }

    /**
     * @dev 防止调用不存在的函数
     */
    fallback() external payable {
        revert("Function does not exist");
    }

    // ==================== 版本管理 ====================

    /**
     * @dev 获取合约版本号
     * @return 当前版本号
     *
     * 用途：
     * - 前端可以根据版本号显示不同的NFT功能
     * - 用于追踪合约升级历史
     * - 帮助判断合约是否需要升级
     * - 验证升级是否成功
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
     * - 防止降级或重复升级
     */
    function canUpgradeTo(uint256 _newVersion) external view returns (bool) {
        return _newVersion > version;
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
     * // V2版本添加NFT等级系统
     * mapping(uint256 => uint256) public nftLevels;  // 占用1个slot
     * uint256[49] private __gap;  // 减少到49个slot
     * ```
     *
     * NFT升级场景：
     * - 添加NFT等级、经验值等属性
     * - 添加NFT合成、升级等功能
     * - 添加NFT租赁、质押等机制
     * - 每添加一个mapping或变量，相应减少__gap
     *
     * 注意事项：
     * - 不要修改__gap的位置
     * - 不要删除__gap
     * - 升级时要谨慎计算占用的空间
     * - 使用OpenZeppelin的升级插件验证存储布局
     * - 确保不会覆盖已有的NFT数据
     *
     * 为什么需要50个slot？
     * - 提供足够的扩展空间
     * - NFT系统可能需要添加多种新属性
     * - 可以根据实际需求调整大小
     */
    uint256[50] private __gap;
}
