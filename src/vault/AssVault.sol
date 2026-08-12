// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {VaultBaseV2} from "../flap/VaultBaseV2.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "../flap/IVaultSchemasV1.sol";

/// @title AssVault — Flap tax vault for Asian Stock Strategy ($ASS)
/// @notice Thin, spec-compliant revenue vault. Accumulates native BNB tax
/// revenue from the Flap TaxProcessor and releases it to the AssEngine, which
/// converts it into the four Asian bStocks for holder distribution. All
/// business logic lives outside this contract to minimise the audited,
/// beacon-upgradeable surface. Deployed behind a BeaconProxy; beacon upgrade
/// authority is transferred to the Flap Guardian per audit requirements.
contract AssVault is Initializable, AccessControlUpgradeable, VaultBaseV2 {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address public taxToken;      // the $ASS token (predicted at creation)
    address public creator;       // wallet that launched via VaultPortal
    address public engine;        // AssEngine — sole destination of released BNB

    uint256 public totalReceived; // lifetime BNB revenue recognised
    uint256 public totalReleased; // lifetime BNB released to the engine

    event EngineSet(address indexed engine);
    event Released(address indexed engine, uint256 amount);

    error CannotRevokeGuardianRole();

    constructor() {
        _disableInitializers(); // implementation is inert; proxies initialize
    }

    function initialize(address taxToken_, address creator_) external initializer {
        require(taxToken_ != address(0), "ASS: zero taxToken");
        require(creator_ != address(0), "ASS: zero creator");
        __AccessControl_init();
        taxToken = taxToken_;
        creator = creator_;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, creator_);
        _grantRole(OPERATOR_ROLE, creator_);
        // MANDATE (VaultBase): Guardian holds every permissioned role,
        // irrevocably by anyone but itself — see revokeRole override.
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, guardian);
    }

    // ------------------------------------------------------------- revenue
    /// @dev MUST stay featherweight: called by the TaxProcessor on dispatch.
    receive() external payable {
        totalReceived += msg.value;
    }

    // ------------------------------------------------------------- release
    function setEngine(address engine_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(engine_ != address(0), "ASS: zero engine");
        engine = engine_;
        emit EngineSet(engine_);
    }

    /// @notice Releases the vault's full BNB balance to the AssEngine.
    /// Operator-gated (keeper/creator/Guardian) — destination is fixed to the
    /// configured engine, so the caller chooses only WHEN, never WHERE.
    function release() external onlyRole(OPERATOR_ROLE) {
        address engine_ = engine;
        require(engine_ != address(0), "ASS: engine unset");
        uint256 amount = address(this).balance;
        require(amount > 0, "ASS: nothing to release");
        totalReleased += amount;
        (bool ok,) = engine_.call{value: amount}("");
        require(ok, "ASS: release failed");
        emit Released(engine_, amount);
    }

    // ------------------------------------------------------------- guardian mandate
    /// @dev Flap-mandated: Guardian's roles are revocable only by the Guardian.
    function revokeRole(bytes32 role, address account)
        public
        override
        onlyRole(getRoleAdmin(role))
    {
        if (account == _getGuardian()) revert CannotRevokeGuardianRole();
        super.revokeRole(role, account);
    }

    // ------------------------------------------------------------- flap spec surface
    function pendingBnb() external view returns (uint256) {
        return address(this).balance;
    }

    function description() public view override returns (string memory) {
        return string.concat(
            "Asian Stock Strategy ($ASS) revenue vault. Tax BNB accumulates here and is "
            "converted into a basket of Binance bStocks (Asian equities) distributed to "
            "$ASS holders. Lifetime BNB received: ",
            _bnbString(totalReceived),
            " | released for stock purchases: ",
            _bnbString(totalReleased),
            " | pending: ",
            _bnbString(address(this).balance),
            ". Docs: assets accrue automatically - hold $ASS, receive Asian stocks."
        );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "AsianStockStrategyVault";
        schema.description =
            "Accumulates $ASS tax revenue (BNB) and routes it to the ASS Engine, which buys "
            "Asian bStocks (BABAB, TSMB, SKHYB, EWYB) and distributes them pro-rata to eligible holders.";
        schema.methods = new VaultMethodSchema[](4);

        schema.methods[0].name = "pendingBnb";
        schema.methods[0].description = "BNB currently held, awaiting release for stock purchases.";
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("pending", "uint256", "Pending BNB", 18);

        schema.methods[1].name = "totalReceived";
        schema.methods[1].description = "Lifetime BNB tax revenue received by the vault.";
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("total", "uint256", "Total BNB received", 18);

        schema.methods[2].name = "totalReleased";
        schema.methods[2].description = "Lifetime BNB released to the engine for bStock purchases.";
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] = FieldDescriptor("total", "uint256", "Total BNB released", 18);

        schema.methods[3].name = "release";
        schema.methods[3].description =
            "Releases accumulated BNB to the ASS Engine for stock purchases. Operator only.";
        schema.methods[3].approvals = new ApproveAction[](0);
        schema.methods[3].isWriteMethod = true;
    }

    // ------------------------------------------------------------- internal
    /// @dev "12.3456 BNB" style, 4dp — enough for a status banner.
    function _bnbString(uint256 wei_) internal pure returns (string memory) {
        uint256 whole = wei_ / 1e18;
        uint256 frac = (wei_ % 1e18) / 1e14;
        bytes memory f = new bytes(4);
        for (uint256 i = 4; i > 0; --i) { f[i - 1] = bytes1(uint8(48 + frac % 10)); frac /= 10; }
        return string.concat(_u(whole), ".", string(f), " BNB");
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v; uint256 d;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { b[--d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}