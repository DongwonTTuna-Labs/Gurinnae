pub(super) fn tool_schema_hashes(tool_id: &str) -> Option<(&'static str, &'static str)> {
    Some(match tool_id {
        "agency.profile" => (
            "32fcac51ce943f4ca5aeaeda5996958a601f2cd89ffb76498c06260d93e67230",
            "400480d8fc62033edb35c75a9b3d3eb0d87822b5d0bcccf24de61d8844c9ca55",
        ),
        "claim.language_check" => (
            "5f997b0ad29c80151e0ddd649f6763f14451b41dd8e653ffbf43eccf2ec0112e",
            "949321557a879a4f05e25ac8315abc27509816c25d17fb3c7a48867314a098c7",
        ),
        "contract.search" => (
            "53023a69e4f010bb1a50868e9da42601b3c71e8c8a2b6c4976574b8512019721",
            "334a5b481f5e8bbe5d52b0c4ea50be5d6d4fadcc08576318513312a7a80076e6",
        ),
        "contract.find_comparables" => (
            "f6cc5c330f6e3fba10784625a7b1ace0b18a6c6684b0934f9a1ee4e342153bb3",
            "d8912d7453096e0cb2d23a2445ca7691c8d7e1e99c9a72fa7b4d632879f4d158",
        ),
        "entity.lookup" => (
            "487ec03b653e0f15a34f936eaea9edb365628ebf5286268682a6fbc444f2b3f8",
            "ed2bc474a805b5854446b4398593143fcc0f14c4294f1758c606bc3afcdd9f31",
        ),
        "evidence.read" => (
            "e659cb038ed233c29a1eee2f6923937e21660f9e7c8b8366bb5b82f87202e073",
            "a95f7d0dabbff40b388bb94f92c458c55168d0bc105b2775d551b61c11f125c1",
        ),
        "evidence.search" => (
            "8773231779b56f840c6fd22250c5d0ecc5e8af476c276a531a35d8e6ab3753e8",
            "3c842109198f09d56b1b8128a50ac725c450233a9634b80311b03f3a191dc387",
        ),
        "relationship.neighbors" => (
            "520f00d9ee779e33a31d9e1ce7d72088feea51bbe8a30ab9518b52789c897679",
            "63dd5666bdd34a681047f334ef02e22da7c9342fb97f38a0a572beeb4d209b29",
        ),
        "response.read" => (
            "4c484e6db2e5d25bbfc764e8f6c7c147b3ea8e1f3381be2cf83d5084471b878e",
            "e47edd531612ed746c0b24a73f2f94122cc2e6e669eeddcb38048b2e0f15469a",
        ),
        "rule.reproduce" => (
            "67725f6210e485ef0f3c64b3611adb5b670822a0ab25ab4d495fb6e1c1cf6676",
            "2e50ec1af02566ab6472d6ceb8b746cbcc246f2fd972b4ba5b758974c970fa0e",
        ),
        "source.fetch" => (
            "e197b3f470dcd2180ad6127c1615684507c10c86cb26c9ee57967f73bff9e57c",
            "c1097a7785d2680e2b27d99133c0f9f37c26f67172cccbc94d9acb9aab7905c6",
        ),
        "source.locator_verify" => (
            "9f21ec92e2bc7716c43f8130e33fc48c65b7cedff152b7ad86b9c1af8eca4ff9",
            "efe7d2d4fab81911f88c6a78f6b6beb1ad0cfdc941ef552508aa0961aa875ef2",
        ),
        "supplier.profile" => (
            "0ecb53a68a6a0eff29ec4b1e56b0061859e8f9b8750a3e2f50be5a96686e870c",
            "e502989a7d06ee5dd7ae73d69b1822fd5dd4bc89c65b6b17553b37193b7149a3",
        ),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::super::sha256;
    use super::tool_schema_hashes;

    const AUTHORITY_SCHEMA_BYTES: [(&str, &[u8], &[u8]); 13] = [
        (
            "agency.profile",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/agency-profile.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/agency-profile.response.schema.json"
            ),
        ),
        (
            "claim.language_check",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/claim-language-check.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/claim-language-check.response.schema.json"
            ),
        ),
        (
            "contract.find_comparables",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/contract-find-comparables.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/contract-find-comparables.response.schema.json"
            ),
        ),
        (
            "contract.search",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/contract-search.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/contract-search.response.schema.json"
            ),
        ),
        (
            "entity.lookup",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/entity-lookup.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/entity-lookup.response.schema.json"
            ),
        ),
        (
            "evidence.read",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/evidence-read.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/evidence-read.response.schema.json"
            ),
        ),
        (
            "evidence.search",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/evidence-search.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/evidence-search.response.schema.json"
            ),
        ),
        (
            "relationship.neighbors",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/relationship-neighbors.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/relationship-neighbors.response.schema.json"
            ),
        ),
        (
            "response.read",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/response-read.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/response-read.response.schema.json"
            ),
        ),
        (
            "rule.reproduce",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/rule-reproduce.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/rule-reproduce.response.schema.json"
            ),
        ),
        (
            "source.fetch",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/source-fetch.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/source-fetch.response.schema.json"
            ),
        ),
        (
            "source.locator_verify",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/source-locator-verify.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/source-locator-verify.response.schema.json"
            ),
        ),
        (
            "supplier.profile",
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/supplier-profile.request.schema.json"
            ),
            include_bytes!(
                "../../../specs/agents/addendum-v2/tools/supplier-profile.response.schema.json"
            ),
        ),
    ];

    #[test]
    fn catalog_is_closed_at_thirteen_tools() {
        let ids = [
            "agency.profile",
            "claim.language_check",
            "contract.find_comparables",
            "contract.search",
            "entity.lookup",
            "evidence.read",
            "evidence.search",
            "relationship.neighbors",
            "response.read",
            "rule.reproduce",
            "source.fetch",
            "source.locator_verify",
            "supplier.profile",
        ];
        assert!(ids.into_iter().all(|id| tool_schema_hashes(id).is_some()));
        assert!(tool_schema_hashes("unknown.tool").is_none());
        assert_eq!(
            tool_schema_hashes("source.fetch"),
            Some((
                "e197b3f470dcd2180ad6127c1615684507c10c86cb26c9ee57967f73bff9e57c",
                "c1097a7785d2680e2b27d99133c0f9f37c26f67172cccbc94d9acb9aab7905c6",
            ))
        );
    }

    #[test]
    fn catalog_hashes_match_exact_authority_schema_bytes() {
        for (tool_id, request, response) in AUTHORITY_SCHEMA_BYTES {
            let hashes = tool_schema_hashes(tool_id);
            assert!(hashes.is_some(), "missing tool schema pin for {tool_id}");
            if let Some((request_pin, response_pin)) = hashes {
                assert_eq!(
                    request_pin,
                    sha256(request),
                    "request pin drift for {tool_id}"
                );
                assert_eq!(
                    response_pin,
                    sha256(response),
                    "response pin drift for {tool_id}"
                );
            }
        }
    }
}
