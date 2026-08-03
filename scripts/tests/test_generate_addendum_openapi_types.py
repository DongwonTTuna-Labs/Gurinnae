from __future__ import annotations

import unittest

import yaml

from scripts.generate_addendum_openapi import (
    ADDENDUM,
    RESOURCES,
    add_contract_schema,
    contract_property,
    operation_node,
    primitive,
)


class AddendumOpenApiBoundedStringTests(unittest.TestCase):
    def test_bounded_uri_reference_preserves_format_and_limits(self) -> None:
        self.assertEqual(
            primitive("uri-reference[1..2000]@body"),
            {
                "type": "string",
                "format": "uri-reference",
                "minLength": 1,
                "maxLength": 2000,
            },
        )

    def test_bounded_json_pointer_preserves_format_and_limits(self) -> None:
        self.assertEqual(
            primitive("json-pointer[1..1000]@body"),
            {
                "type": "string",
                "format": "json-pointer",
                "minLength": 1,
                "maxLength": 1000,
            },
        )


class AddendumOpenApiR6dTypeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.operations = yaml.safe_load(ADDENDUM.read_text())["operations"]
        cls.resource_doc = yaml.safe_load(RESOURCES.read_text())

    def operation_artifacts(self, operation_id: str) -> tuple[dict, dict, dict]:
        operation = next(
            row for row in self.operations if row["operation_id"] == operation_id
        )
        binding = self.resource_doc["operation_bindings"][operation_id]
        schemas: dict = {}
        node = operation_node(
            operation,
            binding,
            schemas,
            self.resource_doc,
            operation["api"] == "control-api",
        )
        return node, schemas, binding

    def schemas_for(self, operation_id: str) -> tuple[dict, dict]:
        _, schemas, binding = self.operation_artifacts(operation_id)
        return schemas, binding

    def test_numeric_const_is_integer_in_request_and_response(self) -> None:
        self.assertEqual(
            primitive("const<1>@body"),
            {"type": "integer", "const": 1},
        )

        schemas, binding = self.schemas_for("attestOrganizationOfficialChannel")
        request = schemas[binding["request_schema"]]
        self.assertEqual(
            request["properties"]["expectedAuthorityVersion"],
            {"type": "integer", "const": 1},
        )

        for operation_id in (
            "classifyEntityPersonhood",
            "attestEntityMaterialUseClosure",
        ):
            with self.subTest(operation_id=operation_id):
                schemas, binding = self.schemas_for(operation_id)
                response = schemas[binding["success_schema"]]
                self.assertEqual(
                    response["properties"]["aggregateVersion"],
                    {"type": "integer", "const": 1},
                )

    def test_const_parser_preserves_boolean_and_string_literals(self) -> None:
        for expression in ("const<false>@body", "const false"):
            with self.subTest(expression=expression):
                self.assertEqual(
                    primitive(expression),
                    {"type": "boolean", "const": False},
                )
        for expression in (
            "const<action-payload.v1>",
            "const action-payload.v1",
        ):
            with self.subTest(expression=expression):
                self.assertEqual(
                    primitive(expression),
                    {"type": "string", "const": "action-payload.v1"},
                )

    def test_r6d_scalar_bounds_are_preserved(self) -> None:
        self.assertEqual(
            primitive("secret-string[1..10000]@body"),
            {"type": "string", "minLength": 1, "maxLength": 10000},
        )
        self.assertEqual(
            primitive("int32[0..1000]@body"),
            {
                "type": "integer",
                "format": "int32",
                "minimum": 0,
                "maximum": 1000,
            },
        )

        schemas, binding = self.schemas_for("classifyEntityPersonhood")
        request = schemas[binding["request_schema"]]
        self.assertEqual(
            request["properties"]["reason"],
            {"type": "string", "minLength": 1, "maxLength": 4000},
        )

        schemas, binding = self.schemas_for("verifyResponseOrganizationIdentity")
        request = schemas[binding["request_schema"]]
        self.assertEqual(
            request["properties"]["expectedVersion"],
            {"type": "integer", "format": "int64", "minimum": 1},
        )

        schemas, binding = self.schemas_for("createPrivacyCorrectionPlan")
        request = schemas[binding["request_schema"]]
        self.assertEqual(
            request["properties"]["expectedDecisionVersion"],
            {"type": "integer", "format": "int64", "minimum": 0},
        )

        schemas, binding = self.schemas_for("attestEntityMaterialUseClosure")
        response = schemas[binding["success_schema"]]
        self.assertEqual(
            response["properties"]["linkedPublicationRevisionCount"],
            {"type": "integer", "format": "int64", "minimum": 0},
        )

    def test_nonempty_string_shorthands_have_minimum_length(self) -> None:
        schemas, binding = self.schemas_for("createPrivacyCorrectionPlan")
        properties = schemas[binding["request_schema"]]["properties"]

        for field in ("requestedValue", "reason"):
            with self.subTest(field=field):
                self.assertEqual(
                    properties[field],
                    {"type": "string", "minLength": 1},
                )

    def test_bounded_unique_uuid_array_preserves_every_constraint(self) -> None:
        expected = {
            "type": "array",
            "items": {"type": "string", "format": "uuid"},
            "minItems": 1,
            "maxItems": 100,
            "uniqueItems": True,
        }
        self.assertEqual(
            primitive("unique-array<uuid>[1..100]@body"),
            expected,
        )

        schemas, binding = self.schemas_for("createPrivacyCorrectionPlan")
        properties = schemas[binding["request_schema"]]["properties"]
        self.assertEqual(properties["evidenceIds"], expected)

    def test_nested_optional_unique_named_array_preserves_reference(self) -> None:
        schemas: dict = {}
        self.assertEqual(
            contract_property(
                "optional<unique-array<ActionKindV1>[1..18]>@query",
                self.resource_doc,
                schemas,
            ),
            {
                "type": "array",
                "items": {"$ref": "#/components/schemas/ActionKindV1"},
                "minItems": 1,
                "maxItems": 18,
                "uniqueItems": True,
            },
        )
        self.assertIn("ActionKindV1", schemas)

    def test_optional_is_omittable_without_becoming_nullable(self) -> None:
        schemas, binding = self.schemas_for("verifyResponseOrganizationIdentity")
        response = schemas[binding["success_schema"]]

        self.assertNotIn("aggregateVersion", response["required"])
        self.assertEqual(
            response["properties"]["aggregateVersion"],
            {"type": "integer", "format": "int64", "minimum": 0},
        )
        self.assertNotIn("anyOf", response["properties"]["aggregateVersion"])

        nullable_uuid = contract_property(
            "nullable<uuid>@body",
            self.resource_doc,
            {},
        )
        self.assertEqual(
            nullable_uuid,
            {
                "anyOf": [
                    {"type": "string", "format": "uuid"},
                    {"type": "null"},
                ]
            },
        )

    def test_integer_query_defaults_are_preserved(self) -> None:
        for operation_id, expected_default in (
            ("listActionApprovalQueue", 20),
            ("listRecordClassSchedules", 100),
        ):
            with self.subTest(operation_id=operation_id):
                node, _, _ = self.operation_artifacts(operation_id)
                limit = next(
                    parameter
                    for parameter in node["parameters"]
                    if parameter["name"] == "limit"
                )
                self.assertEqual(
                    limit["schema"],
                    {
                        "type": "integer",
                        "format": "int32",
                        "minimum": 1,
                        "maximum": 100,
                        "default": expected_default,
                    },
                )

    def test_r6d_retention_query_cursor_and_enum_defaults(self) -> None:
        node, _, _ = self.operation_artifacts("listRetentionRequests")
        parameters = {
            parameter["name"]: parameter["schema"]
            for parameter in node["parameters"]
        }

        self.assertEqual(parameters["cursor"], {"type": "string"})
        self.assertEqual(
            parameters["requestType"],
            {
                "type": "array",
                "items": {
                    "type": "string",
                    "enum": ["ACCESS", "CORRECTION", "DELETION", "RESTRICTION"],
                },
                "minItems": 1,
                "maxItems": 4,
                "uniqueItems": True,
            },
        )
        expected_sort = {
            "type": "string",
            "enum": ["DUE_ASC", "CREATED_DESC"],
            "default": "DUE_ASC",
        }
        self.assertEqual(parameters["sort"], expected_sort)
        self.assertEqual(
            parameters["limit"],
            {
                "type": "integer",
                "format": "int32",
                "minimum": 1,
                "maximum": 100,
                "default": 20,
            },
        )
        self.assertEqual(
            contract_property(
                "optional<enum<DUE_ASC|CREATED_DESC>=DUE_ASC>@query",
                self.resource_doc,
                {},
            ),
            expected_sort,
        )

    def test_r6d_command_receipt_operation_id_preserves_pattern(self) -> None:
        schemas: dict = {}
        add_contract_schema(
            "CommandReceiptV1",
            self.resource_doc,
            schemas,
            set(),
        )

        self.assertEqual(
            schemas["CommandReceiptV1"]["properties"]["operationId"],
            {
                "type": "string",
                "pattern": "^[A-Za-z][A-Za-z0-9]{1,127}$",
            },
        )


if __name__ == "__main__":
    unittest.main()
