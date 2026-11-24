# Sync message constraints

`LastideKit` decodes each sync message into the Codable types in this folder. Codable checks the JSON types, the required fields and the enum values. The `validate` functions check every other constraint of the JSON Schema of revision 4 in `docs/protocol.md`, section 7.3. The section "Revision 4" lists what revision 4 adds. This list names each constraint and the code that checks it.

Terms:

- Code point: one Unicode scalar. Swift counts it with `unicodeScalars.count`, as JSON Schema's `maxLength` does.
- Nullable field: a field that must be present and may hold `null`. `KeyedDecodingContainer.nullable` refuses a missing key, and `encodeNullable` writes `null`.

## Shared definitions

| Schema definition | Constraint | Checked by |
| --- | --- | --- |
| `base` | `type` is a string, `id` and `sentAt` are present | `SyncMessage.decode`, Codable |
| `base.id`, `b64u16` | Canonical base64url of 16 bytes, 22 characters | `Check.b64u16` |
| `b64u32` | Canonical base64url of 32 bytes, 43 characters | `Check.b64u32` |
| `time`, `count`, `storeVersion` | An integer from 0 to 2^53 - 1 | Codable `Int`, `Check.integer` |
| `countOrNull` | A `count` or null. Null means the PC does not measure that count yet | `KeyedDecodingContainer.nullable`, `Check.optionalInteger` |
| `schemaRevision` | An integer from 1 to 65535 | `Check.schemaRevision` |
| `itemId` | `^[A-Za-z0-9._:-]{1,64}$` | `Check.itemID` |
| `projectName` | A string of 1 to 128 code points | `Check.text` |
| `agent`, `draftKind`, `group`, `strength`, `signal` | One listed value | Codable enums in `Values.swift` |
| `agents` | 1 to 2 items, unique | `validateAgents` |
| `scopeFields.scope` | `thisProject`, `kindOfWork` or `everyProject` | `ScopeKind` |
| `scopeFields.kindOfWork` | Nullable; a string of 1 to 128 code points | `Scope.validate` |
| `scopeFields.projectNames` | At most 32 unique project names | `Scope.validate` |
| `thisProject` | `kindOfWork` is null, at least one project | `Scope.validate` |
| `kindOfWork` | `kindOfWork` is a string | `Scope.validate` |
| `everyProject` | `kindOfWork` is null, no project | `Scope.validate` |
| `scopeOption.id` | `^[A-Za-z0-9_-]{1,16}$` | `Check.shortID` |
| `scopeOptions` | 1 to 8 options | `validateOptions` |
| `evidenceItem` | `id` matches `^[A-Za-z0-9_-]{1,16}$`; `at` is a time; `projectName`; `agent`, nullable; `signal`; `commentLabel`, when present, matches `^C[0-9]{1,9}$` | `EvidenceItem` decoding, `EvidenceItem.validate`, `Check.commentLabel` |
| `evidenceItem`, `agent` null | A review comment: `commentLabel` is present and `signal` is `reviewComment` | `EvidenceItem.validate` |
| `draft.text`, `rule.text` | 1 to 4000 code points | `Check.text` |
| `draft.evidence` | At most 20 items | `Draft.validate` |
| `draft.relatedRuleIds` | At most 20 item ids | `Draft.validate` |
| `draft` counters and `createdAt` | Integers from 0 to 2^53 - 1 | `Draft.validate` |
| `rule.source`, `rule.state` | One listed value | `RuleSource`, `RuleState` |
| `rule.approvedAt`, `editedAt`, `lastSeenAt` | Nullable times | `Rule` decoding, `Check.optionalInteger` |
| `rule.editedOn` | Nullable; `desktop` or `phone` | `Rule` decoding, `EditedOn` |
| `rule` counters | Integers from 0 to 2^53 - 1. `violationsSinceApproval` and `violationsLast30Days` are nullable (`countOrNull`) | `Rule` decoding, `Rule.validate` |
| `target` | `targetType` is `draft` or `rule`; `id` is an item id | `Target.validate` |

## Messages

| Message | Constraint | Checked by |
| --- | --- | --- |
| `pair-request` | `ticket` and `phoneId` are b64u16; `phoneKey` is b64u32 | `PairRequest.validate` |
| `pair-request` | `deviceName` has 1 to 64 code points; `model` matches `^[A-Za-z0-9,._-]{1,32}$` | `PairRequest.validate` |
| `pair-request` | `app.version` has 1 to 32 code points; `app.build` is at least 1 | `PairRequest.validate` |
| `pair-request` | `consent.disclosure` is `outside-ai-v1`; `consent.acceptedAt` is a time | `PairRequest.validate` |
| `pair-received` | `pairingId` and `phoneId` are b64u16 | `PairReceived.validate` |
| `pair-accept` | `phoneToken` is b64u32; `pcName` has 1 to 64 code points; `schema` | `PairAccept.validate` |
| `pair-accept` | `features` holds unique values from `mailbox` and `push`, and contains `mailbox` | `PairAccept.validate`, `Feature` |
| `pair-refuse` | `reason` is one of the five listed values | `PairRefuseReason` |
| `queue`, `library` | `schema`, `storeVersion`, `omitted`; every draft or rule | `QueueSnapshot.validate`, `LibrarySnapshot.validate` |
| `counts` | Every number is a count; `repeatCorrectionsThisWeek`, `repeatCorrectionsLastWeek`, `violationsThisWeek` and `draftCap` are nullable (`countOrNull`); `weeks` holds at most 12 items | `Counts` decoding, `Counts.validate` |
| `counts`, revision 2 | `draftingRunsToday`, `draftingRunCap` and `importRulesWaiting` are counts when present, and absent from a revision 1 PC | `Counts` decoding, `Counts.validate` |
| `counts.weeks[]` | `weekStart` matches `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` | `Check.weekStart` |
| `evidence` | `requestId` is b64u16; `draftId` is an item id | `Evidence.validate` |
| `evidence.rationale` | Nullable; at most 1000 code points | `Evidence` decoding and `validate` |
| `evidence.items` | At most 20 items; `evidenceId` matches `^[A-Za-z0-9_-]{1,16}$` | `Evidence.validate`, `EvidenceWords.validate` |
| `evidence.items[].words` | Nullable; at most 300 code points; a non-empty string for state `words`, otherwise null | `EvidenceWords.validate` |
| `acknowledgement` | `decisionId` is b64u16; `appliedAt` is a nullable time; `storeVersion` | `Acknowledgement.validate` |
| `acknowledgement.reason` | Nullable; one of the seven listed values | `RefusalReason` |
| `acknowledgement.current` | Nullable; a draft with `targetType` `draft`, or a rule with `targetType` `rule` | `CurrentItem` |
| `acknowledgement`, `applied` | `appliedAt` is a time and `reason` is null | `Acknowledgement.validate` |
| `acknowledgement`, `refused` | `appliedAt` is null and `reason` is not null | `Acknowledgement.validate` |
| `decision` | `decisionId` is b64u16; `target`; `storeVersion`; `decidedAt` | `Decision.validate` |
| `decision.action` | One of the seven listed values | `DecisionAction` |
| `decision.text` | Nullable; 1 to 500 code points; no carriage return or line feed | `Check.text`, `Check.oneLine` |
| `decision.scopeOptionId` | Nullable; `^[A-Za-z0-9_-]{1,16}$` | `Check.shortID` |
| `sync` | `schema`; `have.queue` and `have.library` are nullable store versions | `SyncRequest.validate`, `SnapshotVersions` |
| `evidence-request` | `draftId` is an item id; `storeVersion`; `replyKey` is b64u32 | `EvidenceRequest.validate` |
| `unpair` | Only the base fields | `Unpair` |
| `error` | `inReplyTo` is a nullable b64u16; `code` is `badMessage` or `unknownType`; `detail` has at most 200 code points | `ErrorMessage.validate` |
| `notice` | `storeVersion`, `queueCount`; `draft` is null or a short draft | `Notice.validate` |
| `notice.draft` | Item id, store version, draft kind, 1 to 600 code points of text, scope | `NoticeDraft.validate` |
| `count-update`, revision 3 | `storeVersion` and `queueCount` are counts. A revision 2 device does not know the type | `CountUpdate.validate`, `SyncMessage.decode(_:revision:)` |

## Revision 4

`LastideKit` decodes at schema revision 4 (`LastideProtocol.schemaRevision`). `SyncMessage.decode(_:revision:)` with a revision of 3 or less answers `unknownType` for the four learning types, as a device of that revision does. A field that revision 4 adds to `counts` or to its weeks may be absent, so a message of an older PC stays as it came. A field that may be absent and may be null decodes to a double optional: `.none` when absent, `.some(nil)` when null (`KeyedDecodingContainer.optionalNullable`).

| Schema definition | Constraint | Checked by |
| --- | --- | --- |
| `learningRef` | `t-` and canonical base64url of 16 bytes: `^t-[A-Za-z0-9_-]{21}[AQgw]$` | `Check.learningRef` |
| `learningDate` | `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` | `Check.weekStart` |
| `learningSpan` | `measured`, `partial` or `notMeasured` | `LearningSpan` |
| `itemIdOrNull`, `timeOrNull`, `categoryOrNull`, `probabilityOrNull` | Nullable fields: an item id, a time, a `group` value or a probability | `KeyedDecodingContainer.nullable`, `Check.itemID`, `Check.optionalInteger`, `Check.optionalProbability` |
| `shortNameOrNull` | Nullable; a string of 1 to 64 code points | `LearningRun.validate` |
| `probability` | A JSON number from 0 to 1 | Codable `Double`, `Check.probability` |
| `learningText` | 1 to 500 code points, with no carriage return or line feed | `Check.learningText` |
| `groupState` | One of the ten listed values | `LearningGroupState` |
| `learningSubject` | `repeatWeek`, `violationWeek` or `rulesApprovedWeek` with a `weekStart` date | `LearningSubject` decoding, `LearningSubject.validate` |
| `learningSubject` | `draftsToday` or `runsToday` with a `day` date, or `rulesOn` alone | `LearningSubject` decoding, `LearningSubject.validate` |
| `learningSubject` | `group`, `rule`, `draft` or `run` with an item id | `LearningSubject` decoding, `LearningSubject.validate` |
| `learningGroupRef` | `size` is a count; `state`; nullable `oneRulePrevents`; `joinedBy` is `lead`, `words`, `model` or null | `LearningGroupRef` decoding, `LearningGroupRef.validate`, `LearningJoin` |
| `learningGroupRef` | Nullable `firstRef`, `firstAt`, `draftId` and `ruleId` | `LearningGroupRef` decoding, `LearningGroupRef.validate`, `LearningJoin` |
| `learningViolation` | `ruleId` is an item id; `ruleText` is a `learningText`; `textCut` is a boolean | `LearningViolation` decoding, `LearningViolation.validate`, `LearningRuleState` |
| `learningViolation` | `ruleState` is `on`, `off` or `deleted`; `ruleApprovedAt` and `answeredAt` are times | `LearningViolation` decoding, `LearningViolation.validate`, `LearningRuleState` |
| `learningViolation` | `covered` and `repeats` are nullable probabilities; `contradicts` is a probability | `LearningViolation` decoding, `LearningViolation.validate`, `LearningRuleState` |
| `learningTurn` | `rowType` is `turn`; `ref`, `at`, `projectName` and `counted` are present | `LearningTurn` decoding, `LearningTurn.validate` |
| `learningTurn` | `agent` is `claudeCode`, `codex` or null; `commentLabel`, when present, is null or matches `^C[0-9]{1,9}$` | `LearningTurn` decoding, `LearningTurn.validate` |
| `learningTurn` | Nullable `signal`, `category`, `kindScore`, `scopeScore`, `questionVersion`, `countedAt` and `group` | `LearningTurn` decoding, `LearningTurn.validate` |
| `learningTurn` | At most 8 `violations`; `violationsLeftOut`, when present, is an integer from 0 to 2^53 - 1 | `LearningTurn` decoding, `LearningTurn.validate` |
| `learningTurn`, `agent` null | A review comment: `commentLabel` is present, and `signal` is `reviewComment` or null | `LearningTurn.validate` |
| `learningRule` | `rowType` is `rule`; `text` is a `learningText`; `state` is `on`, `off` or `deleted` | `LearningRule` decoding, `LearningRule.validate` |
| `learningRule` | `source`, `category`, `scope`, `approvedAt` and `correctionsBeforeApproval`; nullable `violations`, `draftId` and `runId` | `LearningRule` decoding, `LearningRule.validate` |
| `learningDraft` | `rowType` is `draft`; `status` is `waiting`, `approved`, `rejected` or `deleted` | `LearningDraft` decoding, `LearningDraft.validate`, `LearningDraftStatus` |
| `learningDraft` | `text` is a `learningText` or null; `draftKind`, `createdAt`, `category` and `evidenceCount`; nullable `groupId` and `runId` | `LearningDraft` decoding, `LearningDraft.validate`, `LearningDraftStatus` |
| `learningTokens` | `input`, `output` and `cacheRead` are counts; `cacheWrite5m` and `cacheWrite1h` are nullable counts | `LearningTokens` decoding, `LearningTokens.validate` |
| `learningRun` | `rowType` is `run`; `route` is `claudeCode`, `terminal` or `apiKey`; `job` is `draft` or `importMerge` | `LearningRun` decoding, `LearningRun.validate`, `LearningRoute`, `LearningJob`, `LearningRunState`, `LearningOutcome`, `LearningCostMissing` |
| `learningRun` | `state` is `running`, `finished`, `failed` or `lost`; `outcome` is one of the eleven listed values or null | `LearningRun` decoding, `LearningRun.validate`, `LearningRoute`, `LearningJob`, `LearningRunState`, `LearningOutcome`, `LearningCostMissing` |
| `learningRun` | Nullable `endedAt`, `version`, `requestedModel`, `reportedModel`, `tokens`, `costMicros` and `recordedDrafts` | `LearningRun` decoding, `LearningRun.validate`, `LearningRoute`, `LearningJob`, `LearningRunState`, `LearningOutcome`, `LearningCostMissing` |
| `learningRun` | `costMissing` is one of four listed values or null; the other numbers are counts | `LearningRun` decoding, `LearningRun.validate`, `LearningRoute`, `LearningJob`, `LearningRunState`, `LearningOutcome`, `LearningCostMissing` |
| `learningGroup` | `rowType` is `group`; `size`; `state`; nullable `category`, `oneRulePrevents`, `formedAt`, `draftId` and `ruleId` | `LearningGroup` decoding, `LearningGroup.validate` |
| `learningThresholds` | `kind`, `coverage`, `groupReady` and `groupWait` are probabilities | `LearningThresholds.validate` |
| `learning-request` | `subject`; `from` is a count; `listHash` is b64u16 or null | `LearningRequest` decoding, `LearningRequest.validate` |
| `learning-page` | `requestId` is b64u16; `state` is `ok`, `changed`, `gone`, `limited` or `blocked` | `LearningPage` decoding, `LearningPage.validate`, `LearningHead`, `LearningRow` |
| `learning-page` | `subject`, `storeVersion`, `asOf`, `value`, `total`, the three `leftOut` counts, `from` and `thresholds`; nullable `next` | `LearningPage` decoding, `LearningPage.validate`, `LearningHead`, `LearningRow` |
| `learning-page` | `head` is null, a group, a rule, a draft or a run | `LearningPage` decoding, `LearningPage.validate`, `LearningHead`, `LearningRow` |
| `learning-page` | At most 50 `rows`, each a turn, a rule, a draft or a run | `LearningPage` decoding, `LearningPage.validate`, `LearningHead`, `LearningRow` |
| `learning-page`, state `ok` | `listHash` is a b64u16 | `LearningPage.validate` |
| `learning-page`, any other state | `rows` is empty, and `head`, `next` and `listHash` are null | `LearningPage.validate` |
| `learning-words-request` | `ref`; `replyKey` is b64u32 | `LearningWordsRequest.validate` |
| `learning-words` | `requestId` is b64u16; `ref`; `state` is `words`, `removed`, `gone` or `limited`; `words` holds at most 300 code points | `LearningWords` decoding, `LearningWords.validate`, `LearningWordsState` |
| `learning-words`, by state | `words`: a non-empty string and a null `nextAt`. `removed` and `gone`: null `words` and `nextAt`. `limited`: null `words` and an integer `nextAt` | `LearningWords.validate` |
| `counts`, revision 4 | `rulesApprovedThisWeek` and `draftingRunsFinishedToday` are counts; `measuredFrom` is a nullable time; `today` is a `learningDate` | `Counts` decoding, `Counts.validate`, `KeyedDecodingContainer.optionalNullable` |
| `counts`, revision 4 | `repeatCorrectionsLastWeekByNow` and `violationsLastWeekByNow` are nullable counts. Each new field is optional | `Counts` decoding, `Counts.validate`, `KeyedDecodingContainer.optionalNullable` |
| `counts.weeks[]`, revision 4 | `repeatState` and `violationState` are `learningSpan` values; `waiting` is a nullable count; `untraced` is a count. Each is optional | `WeekCount` decoding, `WeekCount.validate` |

## Rules outside the schema

| Rule | Source | Checked by |
| --- | --- | --- |
| Receivers ignore fields this document does not define | Section 7.1 | Codable skips unknown keys |
| A JSON boolean and a JSON number stay apart | JSON Schema types | Codable on Linux, tested in `SyncMessageTests` |
| The plaintext is UTF-8 | Section 5.6, step 6 | `SyncMessage.decode` |
| Each type travels with its kind, direction, flags and slot | Table 20 | `MessageType`, `PCSession.receive`, `PhonePairing.receive` |
| Each decision fits Table 21 before the phone sends it | Section 7.4 | `ReviewStore.decide` |
| A reply key opens one answer, to its own request | Sections 7.2 and 7.6 | `PCSession.receive`, which forgets the key and refuses an answer that names another request |
