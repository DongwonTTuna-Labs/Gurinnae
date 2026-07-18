#![forbid(unsafe_code)]

fn runtime_probe(scenario_id: &str) -> bool {
    std::env::current_exe()
        .map(|path| path.is_file())
        .unwrap_or(false)
        && scenario_id.starts_with("AC-")
        && std::env::var("GURINNAE_ACCEPTANCE_RUNTIME_LAYERS_JSON")
            .map(|value| value.contains("rust-1.97.0-domain-application"))
            .unwrap_or(false)
        && std::env::var("GURINNAE_ACCEPTANCE_OBSERVATION_PATH")
            .map(|value| !value.is_empty())
            .unwrap_or(false)
        && std::env::var("GURINNAE_ACCEPTANCE_EDGE_CONTRACTS_JSON")
            .map(|value| !value.is_empty())
            .unwrap_or(false)
}

#[rustfmt::skip]
#[test]
fn ac_eventing_001() { let scenario_id = "AC-EVENTING-001"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-EVENTING-001", 1, "GI-AC-EVENTING-001-NONE-S-001", "08d5aeac7f429de6299d6bae9c5ea00c882bba7605157fef28557737c11d1ec6", "GH-AC-EVENTING-001-S-001", "0d602c191d64afc81faf38d675da9dc06ad51c226605eb8e4150c13f2f1c1a08", "NONE", "NONE", "03f51482670f4a71a7a5618379ab5b249b3f8156c8cb709874fe8bb744d85cb1", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-EVENTING-001", 2, "GI-AC-EVENTING-001-NONE-S-002", "3ccd4ed7771d4b1142f80562cdc5744f6cfd56c69221339f1fc42090543c1224", "GH-AC-EVENTING-001-S-002", "ad5e28c1bd741a90ae25579c0cf2f9dd041b80379f41abae169d2398aaf0d084", "NONE", "NONE", "03f51482670f4a71a7a5618379ab5b249b3f8156c8cb709874fe8bb744d85cb1", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-001", 3, "GI-AC-EVENTING-001-NONE-S-003", "a5356881f909896b6bbe64bae3d6680b6ebb4adc212441a9d07f71a720d0906a", "GH-AC-EVENTING-001-S-003", "5ff62f4f511b8824f3222a3117846259e9933834ac9678b045d54e9beaaae27d", "NONE", "NONE", "OR-GI-AC-EVENTING-001-NONE-S-003", "f8280034936a7cf4030ee73c4237d8213322b412dbee2222690752839b86ed4d", "03f51482670f4a71a7a5618379ab5b249b3f8156c8cb709874fe8bb744d85cb1", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_eventing_002() { let scenario_id = "AC-EVENTING-002"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-EVENTING-002", 1, "GI-AC-EVENTING-002-NONE-S-001", "263e82a0c25c33aec787ec19082170242b54eb22a5c6fc1ebcad7b044404f487", "GH-AC-EVENTING-002-S-001", "3b88b4118b32fa051c104fc6efa421311454a261b57dbdf8f958bf389ade3fd0", "NONE", "NONE", "ee1ce967d88cfc7c9c16a8e596213db4969741c5febf2f9d930ef7137dc530ad", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-EVENTING-002", 2, "GI-AC-EVENTING-002-NONE-S-002", "396384ff41ce770f7af1259c0e1895f4f20522272b7385c1d3399b7e965690e8", "GH-AC-EVENTING-002-S-002", "85a99cf0e49fa10d9847acf055c92fc4f35f0b554a1931ef16fd262a4cd5d635", "NONE", "NONE", "ee1ce967d88cfc7c9c16a8e596213db4969741c5febf2f9d930ef7137dc530ad", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-002", 3, "GI-AC-EVENTING-002-NONE-S-003", "c72ef71e65ce477615c3a5666337be2e4f0809bc7a138400a5f1b9a16a7f95a1", "GH-AC-EVENTING-002-S-003", "9f16601281db9a893f3afc4edcdb4bf2ca4e3ee1ebe85b6d58ab7b1962dbd0f3", "NONE", "NONE", "OR-GI-AC-EVENTING-002-NONE-S-003", "23f28bccd030dd67790eca723c8854ef7e8bf0fa5aae3b5eff256eeeca31dae6", "ee1ce967d88cfc7c9c16a8e596213db4969741c5febf2f9d930ef7137dc530ad", runtime_ready); ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-002", 4, "GI-AC-EVENTING-002-NONE-S-004", "b4532fe53ce98d5dc884995da7cda57f2f7a4f861e8bd17eaae292a01944d0cf", "GH-AC-EVENTING-002-S-004", "4b348739f1b91eb91b155fa0cdee7ea4f1fdba0ef878b771c89d312e673c6f95", "NONE", "NONE", "OR-GI-AC-EVENTING-002-NONE-S-004", "38e6c80da3a8dd2ea0c0e5a371f905cd03de4558db59098e05dfd1b82634bf79", "ee1ce967d88cfc7c9c16a8e596213db4969741c5febf2f9d930ef7137dc530ad", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_eventing_003() { let scenario_id = "AC-EVENTING-003"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-EVENTING-003", 1, "GI-AC-EVENTING-003-NONE-S-001", "9316b458dcaf1835bce45aa6b05c282991726ba01a1d96f17a3c8f27b79dee4b", "GH-AC-EVENTING-003-S-001", "259b4fd06125753dba1a2c00fd169ff9cbacf491a7b31b78ccc8cba0cc6773d8", "NONE", "NONE", "e5a3328f65feefdeb05b2d0b24043b90b6680880549cec57739e939769fba52a", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-EVENTING-003", 2, "GI-AC-EVENTING-003-NONE-S-002", "e5c3bbf64035d29a5723a1df5a8404b79d5912d37d666320cc29d8c72491b1c7", "GH-AC-EVENTING-003-S-002", "3495015ec1be5afcf83c926e098182bf9b99a3209a110af66a70bda97ace04ff", "NONE", "NONE", "e5a3328f65feefdeb05b2d0b24043b90b6680880549cec57739e939769fba52a", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-003", 3, "GI-AC-EVENTING-003-NONE-S-003", "6f7d69bb20c562a45a1f24a451bdef6974bd756fb22f75540dd4455b7e9a66c6", "GH-AC-EVENTING-003-S-003", "c5462653e4b36ba3d4d25b6fbce4a7660eb1f7474c2fbe1c0f1e745026b68d4c", "NONE", "NONE", "OR-GI-AC-EVENTING-003-NONE-S-003", "4a553c0daedb9f5686db3d99ad9c5610ea7c500f55d5a178519fc91466b92b80", "e5a3328f65feefdeb05b2d0b24043b90b6680880549cec57739e939769fba52a", runtime_ready); ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-003", 4, "GI-AC-EVENTING-003-NONE-S-004", "e6933ffc2b79992c50605d4333c5676c6a4507ec8597114927d59710484bfc11", "GH-AC-EVENTING-003-S-004", "07fcaadca99374a3205acd70972b7c0a17058bb621b4fcaf2300c8a4d1bf761f", "NONE", "NONE", "OR-GI-AC-EVENTING-003-NONE-S-004", "9240504930f92191c372cfdefaa451deec6148df3061a3011a7575d3989eefeb", "e5a3328f65feefdeb05b2d0b24043b90b6680880549cec57739e939769fba52a", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_eventing_004() { let scenario_id = "AC-EVENTING-004"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-EVENTING-004", 1, "GI-AC-EVENTING-004-NONE-S-001", "84c2cf5f787cd6e3dc3cd6aa835a22aaf9b53e3378467508a628454f18ef4f6b", "GH-AC-EVENTING-004-S-001", "aed2ffeb6940762260cf35b19abbe618102c9c444fcec739e6b837054b6be0f5", "NONE", "NONE", "9d90d15558bac4e0c8ee8a208d42aff1bbd0814f7d192f775b565d24ef674a67", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-EVENTING-004", 2, "GI-AC-EVENTING-004-NONE-S-002", "0b64469846fa4eb9210b78af3557ba08969ba503e2cabf34740a5ac26444858d", "GH-AC-EVENTING-004-S-002", "d0ae4711739044afc02d6e581dd257b75e902d991415397acda115d17b243071", "NONE", "NONE", "9d90d15558bac4e0c8ee8a208d42aff1bbd0814f7d192f775b565d24ef674a67", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-004", 3, "GI-AC-EVENTING-004-NONE-S-003", "4df834c2a6caae47b0a6584a8152d76b65611b6f1ad53a7e274f593a58643e2f", "GH-AC-EVENTING-004-S-003", "ec84b05b84ce5b9a8b78195ffc095e113120be96653f0854044f0700b6d4d701", "NONE", "NONE", "OR-GI-AC-EVENTING-004-NONE-S-003", "dd42140ba3d871e82b17208d91d0ebdb07ab0a73749579d431b93e28901f0a15", "9d90d15558bac4e0c8ee8a208d42aff1bbd0814f7d192f775b565d24ef674a67", runtime_ready); ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-004", 4, "GI-AC-EVENTING-004-NONE-S-004", "2352b44b5114e9f66d7b032612b7e83030b1d6a8155814fb6f6546de841663d6", "GH-AC-EVENTING-004-S-004", "6e44d998b0b3a654b0c924baa18aa5a19b090500b17d1c25bc85565f1b3ea610", "NONE", "NONE", "OR-GI-AC-EVENTING-004-NONE-S-004", "66423cee68e276857ceedca473d2cd774b7ece48227154a2a0c010a2527bb60f", "9d90d15558bac4e0c8ee8a208d42aff1bbd0814f7d192f775b565d24ef674a67", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_eventing_005() { let scenario_id = "AC-EVENTING-005"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-EVENTING-005", 1, "GI-AC-EVENTING-005-NONE-S-001", "d7f87158683a07431240d6930ee48f627d626583d46655df2d6bdbfe28072741", "GH-AC-EVENTING-005-S-001", "13503d314a6ef2096c83d660a6b01d279baef99585994c7c359bc415ad251cc5", "NONE", "NONE", "6687a4b7f85e7e39d0eaea0f533e2e903da5188b570036244df9b73f3036bf2c", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-EVENTING-005", 2, "GI-AC-EVENTING-005-NONE-S-002", "465d8a56f4d2d47ed010556dc8b018078b419c4b8cc4b4d8e5b8e65cb728829d", "GH-AC-EVENTING-005-S-002", "5e7509fe243ab7f18a08c4c5b6b2d3fbcb206a3e7a8d66498ccaf3395fa90638", "NONE", "NONE", "6687a4b7f85e7e39d0eaea0f533e2e903da5188b570036244df9b73f3036bf2c", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-005", 3, "GI-AC-EVENTING-005-NONE-S-003", "ca1789e23e7920d635eb58b0d2b7d8802eb207be52b0c5b9f16e3ba6231badb1", "GH-AC-EVENTING-005-S-003", "fce79192323d0943271669f874d149db45d25909c3a8068aab72bdc2201b885b", "NONE", "NONE", "OR-GI-AC-EVENTING-005-NONE-S-003", "0297cce61d81614a476d1b72f84d27fd1d9281ebc52a0278aea2df4a12ed2782", "6687a4b7f85e7e39d0eaea0f533e2e903da5188b570036244df9b73f3036bf2c", runtime_ready); ::gurine_acceptance_testkit::observed_assert!("AC-EVENTING-005", 4, "GI-AC-EVENTING-005-NONE-S-004", "57d164c091257281b68fc15db91dd4a21249421a3bcf24dd2b7c3464c9230dbc", "GH-AC-EVENTING-005-S-004", "6a82e3c797596e000eb1f3e134a54c734d0eb06b56d5c1151ad536502affd6ec", "NONE", "NONE", "OR-GI-AC-EVENTING-005-NONE-S-004", "ed83cd07f57e41d0444d9fccee8b0511e86ef59e88506878e6d83a3802b61a1e", "6687a4b7f85e7e39d0eaea0f533e2e903da5188b570036244df9b73f3036bf2c", runtime_ready); }
