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
fn ac_runtime_configuration_001() { let scenario_id = "AC-RUNTIME_CONFIGURATION-001"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-RUNTIME_CONFIGURATION-001", 1, "GI-AC-RUNTIME_CONFIGURATION-001-NONE-S-001", "6ba8288d875ebe81e3ff38b168b67fc06157c20aa0eb204ddcc315da57ad4556", "GH-AC-RUNTIME_CONFIGURATION-001-S-001", "010b1e65eea21391cd21e40762bb4a4e4dd1ef73973357490a1b827e551a3deb", "NONE", "NONE", "40ce36a0dc5e71cde8d383da7db898013dd09b569e3d84f6c184ea8f9a8cdca3", runtime_ready); ::gurine_acceptance_testkit::observed_assert!("AC-RUNTIME_CONFIGURATION-001", 2, "GI-AC-RUNTIME_CONFIGURATION-001-NONE-S-002", "d9d5e1469f4c681158943400593f8fe2739ab155f509592ffd30ba183f482e9c", "GH-AC-RUNTIME_CONFIGURATION-001-S-002", "46b968ef35ce399d0377dc06238e519b957efadd8272943e230a8603453ebc4b", "NONE", "NONE", "OR-GI-AC-RUNTIME_CONFIGURATION-001-NONE-S-002", "36618a45b9c22df579de5c3cc641cb3b5974a5de5c86716cd9e3bea657ae809b", "40ce36a0dc5e71cde8d383da7db898013dd09b569e3d84f6c184ea8f9a8cdca3", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-RUNTIME_CONFIGURATION-001", 3, "GI-AC-RUNTIME_CONFIGURATION-001-NONE-S-003", "cae55544eb2a88590d6502742f0c44cc8248b82151320b66d3fc1aa9fef2c17e", "GH-AC-RUNTIME_CONFIGURATION-001-S-003", "0c9844bc904c3176508a21eaed99bdaf5c70609199fcf9fe3ca78e3d2a268771", "NONE", "NONE", "OR-GI-AC-RUNTIME_CONFIGURATION-001-NONE-S-003", "103dbd842396d5f7a43f9cb0d12e251d1bc1ddad73368c7980c0e9c7bf6cc65c", "40ce36a0dc5e71cde8d383da7db898013dd09b569e3d84f6c184ea8f9a8cdca3", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_runtime_configuration_002() { let scenario_id = "AC-RUNTIME_CONFIGURATION-002"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-RUNTIME_CONFIGURATION-002", 1, "GI-AC-RUNTIME_CONFIGURATION-002-NONE-S-001", "e606d8283797dc4280603b2ede77b528e00bd42ea62655c8693fcd8beb682b2b", "GH-AC-RUNTIME_CONFIGURATION-002-S-001", "8450ec56c3532015c2387a0d4b44606ec59b12e5a5b6c61763853bd4bf415e18", "NONE", "NONE", "4b505c38c7d8d73ea20a1bb3913e07b0f2aeb56c46d965252de8623307519c33", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-RUNTIME_CONFIGURATION-002", 2, "GI-AC-RUNTIME_CONFIGURATION-002-NONE-S-002", "884c8f05b291588017d6a92d6c01b9fcfeee9a7db590e5e6a2fb41ee6bd018fa", "GH-AC-RUNTIME_CONFIGURATION-002-S-002", "ae87a72919336f1267f1dc63a47c0d97f45e74b44d6d0d60f0e83b416047c0dc", "NONE", "NONE", "4b505c38c7d8d73ea20a1bb3913e07b0f2aeb56c46d965252de8623307519c33", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-RUNTIME_CONFIGURATION-002", 3, "GI-AC-RUNTIME_CONFIGURATION-002-NONE-S-003", "cdcdf89c03d1ee038104776386dd5c7fa0eb26a57249db1ca90424b8e2a2b4b3", "GH-AC-RUNTIME_CONFIGURATION-002-S-003", "01a8d8f61b4262518a8314d322bab75548b84f3b38a8f97596fcb007292cff94", "NONE", "NONE", "OR-GI-AC-RUNTIME_CONFIGURATION-002-NONE-S-003", "39e1944f9753e1ac8fa489ab8ec51b6d77af7804c28fe654bf4b219c944c5e4d", "4b505c38c7d8d73ea20a1bb3913e07b0f2aeb56c46d965252de8623307519c33", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_runtime_configuration_003() { let scenario_id = "AC-RUNTIME_CONFIGURATION-003"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-RUNTIME_CONFIGURATION-003", 1, "GI-AC-RUNTIME_CONFIGURATION-003-NONE-S-001", "d2ac1878e2a0f0bcfd6a6d05b939e5da0c84f58010b775449aa757c168852bc7", "GH-AC-RUNTIME_CONFIGURATION-003-S-001", "5af8513e6f27d1db8f60c3f1c7e5dc5ada4058f08b7cb69de56bffc5c48f6942", "NONE", "NONE", "1ea1e3464da0fc814f19a3a9f122bf419d25a00d675016343880004d2fa07f52", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-RUNTIME_CONFIGURATION-003", 2, "GI-AC-RUNTIME_CONFIGURATION-003-NONE-S-002", "1817095070629ef190da2d581be8b0958fb8dfe490eb68f013370d604cab109b", "GH-AC-RUNTIME_CONFIGURATION-003-S-002", "3ec73b6476ebbccd5852114445416019d06d6f3bf874f3bf1db6c255bc4acde3", "NONE", "NONE", "1ea1e3464da0fc814f19a3a9f122bf419d25a00d675016343880004d2fa07f52", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-RUNTIME_CONFIGURATION-003", 3, "GI-AC-RUNTIME_CONFIGURATION-003-NONE-S-003", "252946a190c0377cae71d68bd46bafbb8b4682c2dbe3ec794557c82712b0317a", "GH-AC-RUNTIME_CONFIGURATION-003-S-003", "5573c6e6713a3aec07d38a52abb7e66f3ed5ed9e468e7c0c3691d234d7b6c61c", "NONE", "NONE", "OR-GI-AC-RUNTIME_CONFIGURATION-003-NONE-S-003", "6e279c15433b4af487b34f36e9ab0d7a314b9f777e16bd80f43a3a4e9ea6be86", "1ea1e3464da0fc814f19a3a9f122bf419d25a00d675016343880004d2fa07f52", runtime_ready); ::gurine_acceptance_testkit::observed_assert!("AC-RUNTIME_CONFIGURATION-003", 4, "GI-AC-RUNTIME_CONFIGURATION-003-NONE-S-004", "3168549670f0f600a514aa9bb1281bca0653bb4c590322e33d491171773afec3", "GH-AC-RUNTIME_CONFIGURATION-003-S-004", "016da9a1ee6d03ea2bebaf9c2a59f7a713c56593fff817c19f31955706fe8e75", "NONE", "NONE", "OR-GI-AC-RUNTIME_CONFIGURATION-003-NONE-S-004", "df771c0232e27af13e00d048c90e2b19fb526ed9d229e8a2225c54141ed2f878", "1ea1e3464da0fc814f19a3a9f122bf419d25a00d675016343880004d2fa07f52", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_runtime_configuration_004() { let scenario_id = "AC-RUNTIME_CONFIGURATION-004"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-RUNTIME_CONFIGURATION-004", 1, "GI-AC-RUNTIME_CONFIGURATION-004-NONE-S-001", "3bc62b8fc67dc9033d1a30446e8862199507e8eea2f9e2c532f73d2ca723d55d", "GH-AC-RUNTIME_CONFIGURATION-004-S-001", "c2518a1d293c7f4aa8c26bef9db29d5a504354868311a13cc94cf96b74a51ec3", "NONE", "NONE", "9a55bd3c38fe1259ea23c7942da535f8a690c36233a037a6f6c42badfef3ad17", runtime_ready); ::gurine_acceptance_testkit::observed_action!("AC-RUNTIME_CONFIGURATION-004", 2, "GI-AC-RUNTIME_CONFIGURATION-004-NONE-S-002", "29bb6b6986a31180df26f6d3affe03d7f1284ad1c8abf62eb43347b822c6ff5c", "GH-AC-RUNTIME_CONFIGURATION-004-S-002", "7fc07cb7806cb48af99d217dd57bb84c009d3997c8366809125b6ffc299dd9b7", "NONE", "NONE", "9a55bd3c38fe1259ea23c7942da535f8a690c36233a037a6f6c42badfef3ad17", runtime_ready);
    ::gurine_acceptance_testkit::observed_assert!("AC-RUNTIME_CONFIGURATION-004", 3, "GI-AC-RUNTIME_CONFIGURATION-004-NONE-S-003", "af43145ba0c0df2a094d2517cd390bc5306af6d068d4ac589aafdfa4e2b96d4f", "GH-AC-RUNTIME_CONFIGURATION-004-S-003", "6a8fb4395cd4db395f7b0772745e9eb79171b797a66587835bbdff46190f2a37", "NONE", "NONE", "OR-GI-AC-RUNTIME_CONFIGURATION-004-NONE-S-003", "9f0f1d133403e20e860674d5a9bf2efae2510afdc27ef014e2f6a03c21a14959", "9a55bd3c38fe1259ea23c7942da535f8a690c36233a037a6f6c42badfef3ad17", runtime_ready); }

#[rustfmt::skip]
#[test]
fn ac_runtime_configuration_005() { let scenario_id = "AC-RUNTIME_CONFIGURATION-005"; let runtime_ready = runtime_probe(scenario_id);
    ::gurine_acceptance_testkit::observed_precondition!("AC-RUNTIME_CONFIGURATION-005", 1, "GI-AC-RUNTIME_CONFIGURATION-005-NONE-S-001", "a8675fee7d067ed53b92268adc8af194d2bd2e2deb2871e1141363a057ffcf59", "GH-AC-RUNTIME_CONFIGURATION-005-S-001", "8d78c25ef57c1b8bb22a63ff1bf081cd311e3b5ac7f9c90295c709cd886515ed", "NONE", "NONE", "7dc49a9a29cdbc528e2ae038659cf902f7c93c493404f0ed82ade7f617e898b4", runtime_ready); ::gurine_acceptance_testkit::observed_assert!("AC-RUNTIME_CONFIGURATION-005", 2, "GI-AC-RUNTIME_CONFIGURATION-005-NONE-S-002", "6fe7c00a1df279f93ecae6b0b227a87b8e1865c5f6d192b269f631e107feed0d", "GH-AC-RUNTIME_CONFIGURATION-005-S-002", "f8a3864f78aacd8342b66588cfdc48629af6dbcf7ef5c350d3cec0859c15c3e9", "NONE", "NONE", "OR-GI-AC-RUNTIME_CONFIGURATION-005-NONE-S-002", "df61ba61b3b515e8f635c6d78fd41d03bfbcb2546c860831e435d7a2b2322c1c", "7dc49a9a29cdbc528e2ae038659cf902f7c93c493404f0ed82ade7f617e898b4", runtime_ready); }
