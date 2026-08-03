from __future__ import annotations

import re
from typing import Any

from .models import Validation


def _closed_string_list(value: Any) -> list[str] | None:
    if (
        not isinstance(value, list)
        or not all(isinstance(item, str) and item for item in value)
        or len(value) != len(set(value))
    ):
        return None
    return value


ROLE_CONTRACT_KEYS = {
    "role",
    "can_login",
    "inherit",
    "superuser",
    "createdb",
    "createrole",
    "replication",
    "bypassrls",
    "connection_limit",
    "memberships_exactly",
}
EXPECTED_RUNTIME_ROLES = (
    {
        "role": "gurine_economics_writer",
        "can_login": False,
        "inherit": False,
        "superuser": False,
        "createdb": False,
        "createrole": False,
        "replication": False,
        "bypassrls": False,
        "connection_limit": -1,
        "memberships_exactly": [],
    },
    {
        "role": "gurine_payment_writer",
        "can_login": False,
        "inherit": False,
        "superuser": False,
        "createdb": False,
        "createrole": False,
        "replication": False,
        "bypassrls": False,
        "connection_limit": -1,
        "memberships_exactly": [],
    },
    {
        "role": "gurine_billing_gateway",
        "can_login": True,
        "inherit": False,
        "superuser": False,
        "createdb": False,
        "createrole": False,
        "replication": False,
        "bypassrls": False,
        "connection_limit": 8,
        "memberships_exactly": [],
    },
    {
        "role": "gurine_economics_importer",
        "can_login": True,
        "inherit": False,
        "superuser": False,
        "createdb": False,
        "createrole": False,
        "replication": False,
        "bypassrls": False,
        "connection_limit": 4,
        "memberships_exactly": [],
    },
)

def _validate_runtime_role_contract(
    contract: dict[str, Any],
    global_contract: dict[str, Any],
    result: Validation,
) -> None:
    role_contract = contract.get("runtime_role_preflight_contract", {})
    roles = role_contract.get("roles")
    valid_rows = isinstance(roles, list) and all(
        isinstance(row, dict) and set(row) == ROLE_CONTRACT_KEYS for row in roles
    )
    result.require(
        valid_rows and tuple(roles) == EXPECTED_RUNTIME_ROLES,
        "0041 runtime role preflight is not the exact closed four-role profile",
    )
    digest = role_contract.get("preflight_do_canonical_sha256")
    result.require(
        isinstance(digest, str)
        and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
        "0041 runtime role preflight DO digest is not final lowercase SHA-256",
    )
    result.require(
        role_contract.get("migration_role_ddl") == "forbidden"
        and isinstance(role_contract.get("provisioning_authority"), str)
        and bool(role_contract.get("provisioning_authority"))
        and isinstance(role_contract.get("prior_authority_rule"), str)
        and bool(role_contract.get("prior_authority_rule")),
        "0041 runtime role provisioning boundary is incomplete",
    )
    acl = contract.get("acl_contract", {})
    result.require(
        acl.get("role_provisioning_precondition")
        == "runtime_role_preflight_contract"
        and acl.get("owner_roles")
        == {
            "economics": "gurine_migrator",
            "payment": "gurine_migrator",
        }
        and acl.get("service_roles")
        == {
            "economics": "gurine_economics_importer",
            "payment": "gurine_billing_gateway",
        },
        "0041 ACL owner and service roles differ from the preflight profile",
    )
    additive = contract.get("additive_role_registry", {})
    additive_rows = additive.get("roles_in_order")
    valid_additive = (
        set(additive)
        == {"base_registry", "roles_in_order", "count_exactly", "merge_rule"}
        and additive.get("base_registry")
        == "specs/database/addendum/global.yaml#privilege_closure.required_roles"
        and additive.get("count_exactly") == 4
        and additive_rows
        == [
            {
                "role": "gurine_economics_writer",
                "schema_usage_exactly": [],
            },
            {
                "role": "gurine_payment_writer",
                "schema_usage_exactly": [],
            },
            {
                "role": "gurine_billing_gateway",
                "schema_usage_exactly": ["ops"],
            },
            {
                "role": "gurine_economics_importer",
                "schema_usage_exactly": ["ops"],
            }
        ]
        and isinstance(additive.get("merge_rule"), str)
        and bool(additive.get("merge_rule"))
    )
    result.require(
        valid_additive,
        "0041 additive role registry is not the exact four-role extension",
    )
    privilege = global_contract.get("privilege_closure", {})
    base_roles = _closed_string_list(privilege.get("required_roles"))
    additive_roles = (
        [row["role"] for row in additive_rows]
        if isinstance(additive_rows, list)
        and all(
            isinstance(row, dict) and isinstance(row.get("role"), str)
            for row in additive_rows
        )
        else []
    )
    effective_roles = set(base_roles or []) | set(additive_roles)
    result.require(
        base_roles is not None
        and not (set(base_roles) & set(additive_roles))
        and len(effective_roles) == len(base_roles) + len(additive_roles)
        and {row["role"] for row in EXPECTED_RUNTIME_ROLES} <= effective_roles,
        "effective runtime roles are not the disjoint global-plus-additive union",
    )
    base_usage = privilege.get("schema_usage", {}).get(
        "expected_application_schema_snapshot"
    )
    effective_usage = dict(base_usage) if isinstance(base_usage, dict) else {}
    for row in additive_rows or []:
        if isinstance(row, dict) and isinstance(row.get("role"), str):
            effective_usage[row["role"]] = row.get("schema_usage_exactly")
    result.require(
        isinstance(base_usage, dict)
        and not ({row["role"] for row in EXPECTED_RUNTIME_ROLES} & set(base_usage))
        and set(effective_usage) == effective_roles | {"gurine_migrator"}
        and effective_usage.get("gurine_economics_writer") == []
        and effective_usage.get("gurine_payment_writer") == []
        and effective_usage.get("gurine_billing_gateway") == ["ops"]
        and effective_usage.get("gurine_economics_importer") == ["ops"],
        "effective schema-USAGE snapshot is not closed over additive runtime roles",
    )
