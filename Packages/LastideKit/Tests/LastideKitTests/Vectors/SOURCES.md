# Vector sources

| File | Source |
| --- | --- |
| `rfc9180-a2.json` | The two entries of the CFRG file `test-vectors.json` with `kem_id` 32, `kdf_id` 1, `aead_id` 3 and `mode` 0 or 2, copied unchanged from https://raw.githubusercontent.com/cfrg/draft-irtf-cfrg-hpke/master/test-vectors.json on 2026-11-18. The `pkRm`, `enc`, `shared_secret`, `key`, `base_nonce` and `exporter_secret` of both entries match RFC 9180 appendices A.2.1 and A.2.3 in https://www.rfc-editor.org/rfc/rfc9180.txt, read the same day. Each entry holds all 257 encryptions and 3 exports. |
| `lastide-v1.json` | The Lastide vector of `docs/protocol.md` section 10.3, generated on the PC side with `@hpke/core` 1.10.1, `@hpke/dhkem-x25519` 1.8.1 and `@hpke/chacha20poly1305` 1.8.1. |
| `lastide-push-v1.json` | The push vector of `docs/protocol.md` section 10.5: one `notice` and one `count-update` in kind 4 envelopes, and one App Attest client data hash. Generated on the PC side with the same libraries, from the seeds and keys of `lastide-v1.json`. |
