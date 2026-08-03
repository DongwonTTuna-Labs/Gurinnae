import { expect } from "@playwright/test";
import {
  arrayValue,
  assertUnique,
  booleanValue,
  catalogScreens,
  type Operation,
  objectValue,
  operationContracts,
  operationMap,
  stringList,
  stringValue,
  yamlObject,
} from "./screen-contract-assertions";

type Action = ReturnType<typeof catalogScreens>[number]["actions"][number];
type CommandSemantics = {
  operationId: string;
  capability: string;
  assurance: string;
  stepUp: boolean;
  preconditions: unknown[];
  statements: unknown[];
  errorGroups: unknown[];
  receipt: string;
};
type ProposalEntry = {
  legacyOperationId: string;
  requiredEntryOperation: string;
};

const INTERACTIONS = new Set([
  "NAVIGATION",
  "COMMAND",
  "DOWNLOAD",
  "EXTERNAL_LINK",
  "DESTRUCTIVE_CONFIRMATION",
  "FORM_SUBMIT",
]);
const ASSURANCES = new Set([
  "NONE",
  "ANONYMOUS_PROOF",
  "SCOPED_TOKEN",
  "ACTIVE_SESSION",
  "RECENT_SESSION",
  "STEP_UP",
]);

function capabilityRegistry(): string[] {
  const roles = yamlObject("specs/ui/roles-and-permissions.yaml");
  const baseCapabilities = stringList(
    arrayValue(roles.capabilities, "capabilities").map((entry, index) =>
      stringValue(
        objectValue(entry, `capabilities[${index}]`).id,
        `capabilities[${index}].id`,
      ),
    ),
    "capability ids",
  );
  const authorizationDelta = objectValue(
    yamlObject("specs/product/owner-addendum-2026-07-14.yaml")
      .authorization_delta,
    "authorization_delta",
  );
  const additiveCapabilities = stringList(
    arrayValue(
      authorizationDelta.capabilities,
      "authorization_delta.capabilities",
    ).map((entry, index) =>
      stringValue(
        objectValue(entry, `authorization_delta.capabilities[${index}]`).id,
        `authorization_delta.capabilities[${index}].id`,
      ),
    ),
    "additive capability ids",
  );
  return [...baseCapabilities, ...additiveCapabilities];
}

function commandSemantics(): CommandSemantics[] {
  const document = yamlObject("specs/application/command-semantics.yaml");
  const base = arrayValue(document.commands, "commands").map((value, index) => {
    const context = `commands[${index}]`;
    const item = objectValue(value, context);
    const authorization = objectValue(
      item.authorization,
      `${context}.authorization`,
    );
    const transaction = objectValue(item.transaction, `${context}.transaction`);
    return {
      operationId: stringValue(item.operation_id, `${context}.operation_id`),
      capability: stringValue(
        authorization.capability,
        `${context}.authorization.capability`,
      ),
      assurance: stringValue(
        authorization.assurance_level,
        `${context}.authorization.assurance_level`,
      ),
      stepUp: booleanValue(
        authorization.step_up_required,
        `${context}.authorization.step_up_required`,
      ),
      preconditions: arrayValue(item.preconditions, `${context}.preconditions`),
      statements: arrayValue(
        transaction.statements,
        `${context}.transaction.statements`,
      ),
      errorGroups: Object.values(objectValue(item.errors, `${context}.errors`)),
      receipt: stringValue(item.receipt, `${context}.receipt`),
    };
  });
  const addendum = objectValue(
    yamlObject("specs/product/addendum-command-semantics.yaml")
      .external_commands,
    "addendum external commands",
  );
  return [
    ...base,
    ...Object.entries(addendum).map(([operationId, value]) => {
      const context = `external_commands.${operationId}`;
      const item = objectValue(value, context);
      const authorization = objectValue(
        item.authorization,
        `${context}.authorization`,
      );
      const transaction = objectValue(
        item.transaction,
        `${context}.transaction`,
      );
      const errors = objectValue(item.errors, `${context}.errors`);
      const receipt = objectValue(item.receipt, `${context}.receipt`);
      const assurance = stringValue(
        authorization.assurance,
        `${context}.authorization.assurance`,
      );
      return {
        operationId: stringValue(item.operation_id, `${context}.operation_id`),
        capability:
          authorization.capability === null
            ? "none"
            : stringValue(
                authorization.capability,
                `${context}.authorization.capability`,
              ),
        assurance,
        stepUp: assurance === "STEP_UP",
        preconditions: [authorization],
        statements: arrayValue(
          transaction.statements,
          `${context}.transaction.statements`,
        ),
        errorGroups: [
          arrayValue(errors.exact_codes, `${context}.errors.exact_codes`),
        ],
        receipt: stringValue(receipt.schema, `${context}.receipt.schema`),
      };
    }),
  ];
}

function proposalEntryOperations(): Map<string, ProposalEntry> {
  const document = yamlObject("specs/ui/screen-action-contracts.yaml");
  const rows = arrayValue(
    document.legacy_side_door_fences,
    "legacy_side_door_fences",
  );
  const entries = rows.flatMap((value, index) => {
    const context = `legacy_side_door_fences[${index}]`;
    const row = objectValue(value, context);
    if (row.proposal_binding === undefined) return [];
    const binding = objectValue(
      row.proposal_binding,
      `${context}.proposal_binding`,
    );
    const screenId = stringValue(row.screen_id, `${context}.screen_id`);
    const actionId = stringValue(
      row.legacy_action_id,
      `${context}.legacy_action_id`,
    );
    const legacyOperationId = stringValue(
      row.legacy_operation_id,
      `${context}.legacy_operation_id`,
    );
    expect(row.policy, `${context} policy`).toBe(
      "PROPOSAL_ONLY_UNTIL_AUTHORIZED_EXECUTION",
    );
    expect(row.direct_effect_forbidden, `${context} direct-effect fence`).toBe(
      true,
    );
    expect(Object.keys(binding).sort(), `${context} binding fields`).toEqual([
      "actionKind",
      "providerControl.operationId",
    ]);
    expect(binding.actionKind, `${context} action kind`).toBe(
      "PROVIDER_CONTROL",
    );
    expect(
      binding["providerControl.operationId"],
      `${context} provider operation binding`,
    ).toBe(legacyOperationId);
    return [
      [
        `${screenId}.${actionId}`,
        {
          legacyOperationId,
          requiredEntryOperation: stringValue(
            row.required_entry_operation,
            `${context}.required_entry_operation`,
          ),
        },
      ] as const,
    ];
  });
  assertUnique(
    entries.map(([key]) => key),
    "proposal entry action keys unique",
  );
  return new Map(entries);
}

function assertBaseAction(
  action: Action,
  capabilities: string[],
  operations: Map<string, Operation>,
): void {
  expect(
    INTERACTIONS.has(action.interaction),
    `${action.id} interaction kind`,
  ).toBe(true);
  expect(ASSURANCES.has(action.assurance), `${action.id} assurance`).toBe(true);
  expect(action.stepUp, `${action.id} step-up rule`).toBe(
    action.assurance === "STEP_UP",
  );
  expect(action.confirmation, `${action.id} confirmation rule`).toBe(
    action.interaction === "DESTRUCTIVE_CONFIRMATION",
  );
  if (action.capability !== "none")
    expect(capabilities, `${action.id} capability`).toContain(
      action.capability,
    );
  if (!action.localOnly)
    expect(action.operationId, `${action.id} server operation`).toBeDefined();
  if (!action.operationId) return;
  const operation = operations.get(action.operationId);
  expect(operation, `${action.id} operation contract`).toBeDefined();
  if (operation?.mutatesState)
    expect(
      operation.kind,
      `${action.id} mutation classified by operation contract`,
    ).toBe("COMMAND");
}

function assertMutationClosure(
  action: Action,
  operations: Map<string, Operation>,
  commands: Map<string, CommandSemantics>,
): void {
  if (!action.operationId)
    throw new Error(`${action.id} mutation has no operation`);
  const operation = operations.get(action.operationId);
  const command = commands.get(action.operationId);
  expect(command, `${action.operationId} command semantics`).toBeDefined();
  if (!operation || !command) return;
  expect(
    [command.capability, command.assurance, command.stepUp],
    `${action.operationId} authorization closure`,
  ).toEqual([operation.capability, operation.assurance, operation.stepUp]);
  expect(
    command.preconditions.length,
    `${action.operationId} preconditions`,
  ).toBeGreaterThan(0);
  expect(
    command.statements.length,
    `${action.operationId} transaction`,
  ).toBeGreaterThan(0);
  expect(
    command.errorGroups.length,
    `${action.operationId} error groups`,
  ).toBeGreaterThan(0);
  for (const group of command.errorGroups)
    expect(
      Array.isArray(group),
      `${action.operationId} error group shape`,
    ).toBe(true);
  expect(
    command.receipt.length,
    `${action.operationId} receipt`,
  ).toBeGreaterThan(0);
}

export function assertActionGuards(): void {
  const actionEntries = catalogScreens().flatMap((screen) =>
    screen.actions.map((action) => ({ screenId: screen.id, action })),
  );
  const capabilities = capabilityRegistry();
  const operations = operationMap(operationContracts());
  const commands = commandSemantics();
  const proposalEntries = proposalEntryOperations();
  expect(actionEntries, "base screen actions").toHaveLength(259);
  expect(proposalEntries.size, "explicit provider proposal entries").toBe(4);
  expect(capabilities.length, "non-none capability registry").toBeGreaterThan(
    0,
  );
  assertUnique(capabilities, "capability registry unique");
  expect(commands, "command semantics").toHaveLength(142);
  assertUnique(
    commands.map((command) => command.operationId),
    "command semantics operation ids unique",
  );
  const effectiveActions = actionEntries.map(({ screenId, action }) => {
    const entry = proposalEntries.get(`${screenId}.${action.id}`);
    if (!entry) return action;
    expect(
      action.operationId,
      `${screenId}.${action.id} legacy operation`,
    ).toBe(entry.legacyOperationId);
    expect(
      operations.has(entry.requiredEntryOperation),
      `${screenId}.${action.id} proposal entry operation`,
    ).toBe(true);
    return { ...action, operationId: entry.requiredEntryOperation };
  });
  for (const action of effectiveActions)
    assertBaseAction(action, capabilities, operations);
  const mutations = effectiveActions.filter(
    (action) =>
      action.operationId !== undefined &&
      operations.get(action.operationId)?.mutatesState === true,
  );
  expect(mutations, "mutating screen actions").toHaveLength(108);
  const commandMap = new Map(
    commands.map((command) => [command.operationId, command]),
  );
  for (const mutation of mutations)
    assertMutationClosure(mutation, operations, commandMap);
  // The mock can verify declared guards, but only a real server can prove authorization is re-evaluated.
}
