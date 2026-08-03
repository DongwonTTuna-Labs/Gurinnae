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
  return stringList(
    arrayValue(roles.capabilities, "capabilities").map((entry, index) =>
      stringValue(
        objectValue(entry, `capabilities[${index}]`).id,
        `capabilities[${index}].id`,
      ),
    ),
    "capability ids",
  );
}

function commandSemantics(): CommandSemantics[] {
  const document = yamlObject("specs/application/command-semantics.yaml");
  return arrayValue(document.commands, "commands").map((value, index) => {
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
  const actions = catalogScreens().flatMap((screen) => screen.actions);
  const capabilities = capabilityRegistry();
  const operations = operationMap(operationContracts());
  const commands = commandSemantics();
  expect(actions, "base screen actions").toHaveLength(250);
  expect(capabilities.length, "non-none capability registry").toBeGreaterThan(
    0,
  );
  assertUnique(capabilities, "capability registry unique");
  expect(commands, "command semantics").toHaveLength(105);
  assertUnique(
    commands.map((command) => command.operationId),
    "command semantics operation ids unique",
  );
  for (const action of actions)
    assertBaseAction(action, capabilities, operations);
  const mutations = actions.filter(
    (action) =>
      action.operationId !== undefined &&
      operations.get(action.operationId)?.mutatesState === true,
  );
  expect(mutations, "mutating screen actions").toHaveLength(109);
  const commandMap = new Map(
    commands.map((command) => [command.operationId, command]),
  );
  for (const mutation of mutations)
    assertMutationClosure(mutation, operations, commandMap);
  // The mock can verify declared guards, but only a real server can prove authorization is re-evaluated.
}
