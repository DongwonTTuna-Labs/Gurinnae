pub(super) fn tool_schema_hashes(tool_id: &str) -> Option<(&'static str, &'static str)> {
    Some(match tool_id {
        "agency.profile" => (
            "32fcac51ce943f4ca5aeaeda5996958a601f2cd89ffb76498c06260d93e67230",
            "400480d8fc62033edb35c75a9b3d3eb0d87822b5d0bcccf24de61d8844c9ca55",
        ),
        "claim.language_check" => (
            "5f997b0ad29c80151e0ddd649f6763f14451b41dd8e653ffbf43eccf2ec0112e",
            "ac77f413e976813197b57db66a5737178c87f51ba7d67b19bc31aa80b7c0dbf6",
        ),
        "contract.search" => (
            "53023a69e4f010bb1a50868e9da42601b3c71e8c8a2b6c4976574b8512019721",
            "334a5b481f5e8bbe5d52b0c4ea50be5d6d4fadcc08576318513312a7a80076e6",
        ),
        "contract.find_comparables" => (
            "84fc62d88f8c6d61717fcf7e025cc4e7b4825703cb147d207ba6a92d8875a5c0",
            "15f512d7b8d1ddb98c09e04ece72c0907e29c21a38501bb539d86e43881e64fe",
        ),
        "entity.lookup" => (
            "19133149878dbbf54ef7865f1822c77ea2c31aac8bcfcc377ad4869e18bb713d",
            "0dc88f3b5cac41877326f3f6cbf5a86a8859e4124bdc387adc7816c3444256a1",
        ),
        "evidence.read" => (
            "71ba7e5b3d0867e7ac36354f82d42cf8533c1ed93b49426f248cc9147a6b8bde",
            "ec19aa983c3c786da78f4e2bc41e6398c6af24ae8d3506ee4cf0848a4a0fa4e0",
        ),
        "evidence.search" => (
            "d92f236d62ab15ddb3ba12af5f63079e2293057d7d5d21f5d43280306ca54c42",
            "cc44ee052c404fae5fd5945e483d60966e76b1f44c1ebfea576b19444bc651ca",
        ),
        "relationship.neighbors" => (
            "9f0443d480d37d32dd1de1b861730a3d0fa7a3cab5a1bb9a9add1cfef0b2b4e3",
            "3486871d493be124039b6ae170aa1a33854645ec63abc735d26dc12c49f245b9",
        ),
        "response.read" => (
            "87e0332aed2c7de8f604db95a629159856426e3f8e4f2649194c5148716d74ee",
            "f751a34a8f78407894ff96605241928d3fecee2f7ff9b48ba130ecb48701855f",
        ),
        "rule.reproduce" => (
            "ba0e45b6c03dad44a99299fc5a06058e740500dabe60f6af13cc77ebc5fd4147",
            "8104f45d77b0d576e986844e09b34370c642042ebe8d7c8a8dc3d68fbf9b21ff",
        ),
        "source.fetch" => (
            "8a6083ee948e416f71d7ee7e34ddb6ca41e84a8e3a2d1be53c4900605dc80c67",
            "42e59f2ddbe8bf2c58e61451cd698e388463f42bcdc13394bb6bf5140ca5912e",
        ),
        "source.locator_verify" => (
            "3470624bf89ed5d2116d7ef365b4dd017e822736f5b8d71189c7312653a5512f",
            "d8ddd0649eb49c0f0d8bc9490fb48134cb383cfa671d53d6ad710be39bd998ad",
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
    use super::tool_schema_hashes;

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
    }
}
