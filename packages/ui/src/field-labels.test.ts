import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";
import { describe, expect, it } from "vitest";
import { rowNavigationResponseBody } from "../../../tests/e2e/support/mock-api-row-navigation";
import operationSamples from "../../../verification/generated-operation-samples.json";
import {
  indexOperations,
  type OpenApiDocument,
  operationFields,
} from "../../config/src/screen-runtime";
import {
  explicitKoreanContextLabel,
  FIELD_LABEL_GROUPS,
  FIELD_LABELS,
  fieldLabel,
} from "./field-labels";
import {
  SCREEN_PROJECTION_BINDINGS,
  type ScreenProjectionBinding,
} from "./generated-screen-projections";

const MOCK_SUPPORT_DIRECTORY = fileURLToPath(
  new URL("../../../tests/e2e/support/", import.meta.url),
);
const FIELD_LABEL_DIRECTORY = fileURLToPath(
  new URL("./field-labels/", import.meta.url),
);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function collectNestedKeys(value: unknown, result: Set<string>): void {
  if (Array.isArray(value)) {
    for (const item of value) collectNestedKeys(item, result);
    return;
  }
  if (!isRecord(value)) return;
  for (const [key, child] of Object.entries(value)) {
    result.add(key);
    collectNestedKeys(child, result);
  }
}

function operationSampleFields(): Set<string> {
  const result = new Set<string>();
  for (const sample of Object.values(operationSamples)) {
    if (isRecord(sample) && "body" in sample)
      collectNestedKeys(sample.body, result);
  }
  return result;
}

function projectionFields(): Set<string> {
  const bindings: Readonly<
    Record<string, Readonly<Record<string, ScreenProjectionBinding>>>
  > = SCREEN_PROJECTION_BINDINGS;
  return new Set(
    Object.values(bindings).flatMap((screen) =>
      Object.values(screen).map((binding) => binding.fieldName),
    ),
  );
}

function screenOperationFields(): Set<string> {
  const documents = [
    "public-api",
    "submission-api",
    "identity-provider",
    "control-api",
  ].map(
    (api) =>
      JSON.parse(
        readFileSync(
          fileURLToPath(
            new URL(
              `../../../specs/generated/${api}.openapi.json`,
              import.meta.url,
            ),
          ),
          "utf8",
        ),
      ) as OpenApiDocument,
  );
  const operations = indexOperations(documents);
  const catalog = readFileSync(
    fileURLToPath(
      new URL("../../../specs/ui/screen-catalog.yaml", import.meta.url),
    ),
    "utf8",
  );
  const operationIds = new Set(
    [...catalog.matchAll(/^\s*(?:-\s*)?operation_id:\s*([^\s#]+)/gmu)].flatMap(
      (match) => (match[1] ? [match[1]] : []),
    ),
  );
  const result = new Set<string>();
  for (const operationId of operationIds) {
    const operation = operations.get(operationId);
    if (!operation) throw new Error(`화면 API 작업 계약 누락: ${operationId}`);
    for (const field of operationFields(operation, {})) result.add(field.name);
  }
  return result;
}

function literalPropertyName(
  property: ts.ObjectLiteralElementLike,
): string | null {
  if (
    !ts.isPropertyAssignment(property) &&
    !ts.isShorthandPropertyAssignment(property)
  )
    return null;
  const name = property.name;
  return ts.isIdentifier(name) ||
    ts.isStringLiteral(name) ||
    ts.isNumericLiteral(name)
    ? name.text
    : null;
}

function objectLiteral(
  expression: ts.Expression | undefined,
): ts.ObjectLiteralExpression | null {
  let current = expression;
  while (
    current &&
    (ts.isParenthesizedExpression(current) ||
      ts.isAsExpression(current) ||
      ts.isTypeAssertionExpression(current) ||
      ts.isSatisfiesExpression(current) ||
      ts.isNonNullExpression(current))
  )
    current = current.expression;
  return current && ts.isObjectLiteralExpression(current) ? current : null;
}

function duplicateSourceKeys(): string[] {
  const duplicates: string[] = [];
  for (const file of readdirSync(FIELD_LABEL_DIRECTORY)
    .filter((name) => /^[a-z]-[a-z]\.ts$/u.test(name))
    .sort()) {
    const source = ts.createSourceFile(
      file,
      readFileSync(`${FIELD_LABEL_DIRECTORY}/${file}`, "utf8"),
      ts.ScriptTarget.Latest,
      true,
    );
    const visit = (node: ts.Node) => {
      if (
        ts.isVariableDeclaration(node) &&
        ts.isIdentifier(node.name) &&
        node.name.text.startsWith("FIELD_LABELS_")
      ) {
        const entries = objectLiteral(node.initializer);
        if (!entries) throw new Error(`필드 라벨 원천 객체 누락: ${file}`);
        const seen = new Set<string>();
        for (const property of entries.properties) {
          const name = literalPropertyName(property);
          if (!name) throw new Error(`필드 라벨 키 형식 오류: ${file}`);
          if (seen.has(name)) duplicates.push(`${file}:${name}`);
          seen.add(name);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return duplicates;
}

type MockKeyCollector = {
  result: Set<string>;
  checker: ts.TypeChecker;
  sources: ReadonlySet<ts.SourceFile>;
  resolving: Set<ts.Symbol>;
};

function collectExpressionKeys(
  expression: ts.Expression | undefined,
  collector: MockKeyCollector,
): void {
  if (!expression) return;
  if (
    ts.isParenthesizedExpression(expression) ||
    ts.isAsExpression(expression) ||
    ts.isTypeAssertionExpression(expression) ||
    ts.isSatisfiesExpression(expression) ||
    ts.isNonNullExpression(expression)
  ) {
    collectExpressionKeys(expression.expression, collector);
    return;
  }
  if (ts.isObjectLiteralExpression(expression)) {
    for (const property of expression.properties) {
      if (ts.isSpreadAssignment(property)) {
        collectExpressionKeys(property.expression, collector);
        continue;
      }
      const name = literalPropertyName(property);
      if (name) collector.result.add(name);
      if (ts.isPropertyAssignment(property))
        collectExpressionKeys(property.initializer, collector);
      if (ts.isShorthandPropertyAssignment(property))
        collectExpressionKeys(property.name, collector);
    }
    return;
  }
  if (ts.isArrayLiteralExpression(expression)) {
    for (const element of expression.elements)
      if (ts.isExpression(element)) collectExpressionKeys(element, collector);
    return;
  }
  if (ts.isIdentifier(expression)) {
    collectSymbolKeys(resolvedSymbol(collector.checker, expression), collector);
    return;
  }
  if (ts.isCallExpression(expression) || ts.isNewExpression(expression)) {
    for (const argument of expression.arguments ?? [])
      collectExpressionKeys(argument, collector);
    if (ts.isCallExpression(expression)) {
      const callee = expression.expression;
      if (ts.isArrowFunction(callee) || ts.isFunctionExpression(callee))
        collectFunctionKeys(callee, collector);
      else
        collectSymbolKeys(
          resolvedSymbol(
            collector.checker,
            ts.isPropertyAccessExpression(callee) ? callee.name : callee,
          ),
          collector,
        );
    }
    return;
  }
  if (ts.isArrowFunction(expression) || ts.isFunctionExpression(expression)) {
    collectFunctionKeys(expression, collector);
    return;
  }
  if (ts.isConditionalExpression(expression)) {
    collectExpressionKeys(expression.whenTrue, collector);
    collectExpressionKeys(expression.whenFalse, collector);
    return;
  }
  if (ts.isBinaryExpression(expression)) {
    collectExpressionKeys(expression.left, collector);
    collectExpressionKeys(expression.right, collector);
    return;
  }
  if (
    ts.isAwaitExpression(expression) ||
    ts.isYieldExpression(expression) ||
    ts.isSpreadElement(expression)
  ) {
    collectExpressionKeys(expression.expression, collector);
    return;
  }
  if (ts.isPropertyAccessExpression(expression)) {
    collectSymbolKeys(
      resolvedSymbol(collector.checker, expression.name),
      collector,
    );
    return;
  }
  if (ts.isElementAccessExpression(expression))
    collectSymbolKeys(resolvedSymbol(collector.checker, expression), collector);
}

function resolvedSymbol(
  checker: ts.TypeChecker,
  node: ts.Node,
): ts.Symbol | undefined {
  let symbol = checker.getSymbolAtLocation(node);
  const aliases = new Set<ts.Symbol>();
  while (
    symbol &&
    (symbol.flags & ts.SymbolFlags.Alias) !== 0 &&
    !aliases.has(symbol)
  ) {
    aliases.add(symbol);
    symbol = checker.getAliasedSymbol(symbol);
  }
  return symbol;
}

function collectFunctionKeys(
  declaration: ts.FunctionLikeDeclaration,
  collector: MockKeyCollector,
): void {
  const body = declaration.body;
  if (!body) return;
  if (!ts.isBlock(body)) {
    collectExpressionKeys(body, collector);
    return;
  }
  const visit = (node: ts.Node) => {
    if (node !== body && ts.isFunctionLike(node)) return;
    if (ts.isReturnStatement(node))
      collectExpressionKeys(node.expression, collector);
    ts.forEachChild(node, visit);
  };
  visit(body);
}

function isFunctionLikeDeclaration(
  node: ts.Node,
): node is ts.FunctionLikeDeclaration {
  return (
    ts.isFunctionDeclaration(node) ||
    ts.isMethodDeclaration(node) ||
    ts.isGetAccessorDeclaration(node) ||
    ts.isSetAccessorDeclaration(node) ||
    ts.isConstructorDeclaration(node) ||
    ts.isFunctionExpression(node) ||
    ts.isArrowFunction(node)
  );
}

function collectSymbolKeys(
  symbol: ts.Symbol | undefined,
  collector: MockKeyCollector,
): void {
  if (!symbol || collector.resolving.has(symbol)) return;
  collector.resolving.add(symbol);
  for (const declaration of symbol.declarations ?? []) {
    if (!collector.sources.has(declaration.getSourceFile())) continue;
    if (
      ts.isVariableDeclaration(declaration) ||
      ts.isPropertyAssignment(declaration) ||
      ts.isBindingElement(declaration)
    )
      collectExpressionKeys(declaration.initializer, collector);
    else if (isFunctionLikeDeclaration(declaration))
      collectFunctionKeys(declaration, collector);
  }
  collector.resolving.delete(symbol);
}

function collectMockFileFields(
  source: ts.SourceFile,
  collector: MockKeyCollector,
): void {
  const visit = (node: ts.Node) => {
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      node.expression.expression.getText(source) === "Response" &&
      node.expression.name.text === "json"
    )
      collectExpressionKeys(node.arguments[0], collector);
    ts.forEachChild(node, visit);
  };
  visit(source);
}

function rowNavigationResponseFields(result: Set<string>): void {
  for (const [operationId, sample] of Object.entries(operationSamples)) {
    if (!isRecord(sample) || !("body" in sample)) continue;
    collectNestedKeys(
      rowNavigationResponseBody(operationId, sample.body),
      result,
    );
  }
}

function mockResponseFields(): Set<string> {
  const result = operationSampleFields();
  const files = readdirSync(MOCK_SUPPORT_DIRECTORY)
    .filter((file) => /^mock-api.*\.ts$/u.test(file))
    .sort();
  const paths = files.map((file) => `${MOCK_SUPPORT_DIRECTORY}/${file}`);
  const program = ts.createProgram({
    rootNames: paths,
    options: {
      module: ts.ModuleKind.ESNext,
      moduleResolution: ts.ModuleResolutionKind.Bundler,
      resolveJsonModule: true,
      skipLibCheck: true,
      target: ts.ScriptTarget.Latest,
    },
  });
  const sources = paths.map((path) => {
    const source = program.getSourceFile(path);
    if (!source) throw new Error(`mock 응답 소스 누락: ${path}`);
    return source;
  });
  const mockSources = new Set(sources);
  const checker = program.getTypeChecker();
  const collector = {
    result,
    checker,
    sources: mockSources,
    resolving: new Set<ts.Symbol>(),
  };
  for (const source of sources) collectMockFileFields(source, collector);
  rowNavigationResponseFields(result);
  return result;
}

function missingLabels(fields: ReadonlySet<string>): string[] {
  return [...fields]
    .filter((field) => !Object.hasOwn(FIELD_LABELS, field))
    .sort();
}

describe("closed Korean field-label registry", () => {
  it("covers every field rendered by the 94-screen operation forms", () => {
    const fields = screenOperationFields();
    expect(fields.size).toBe(224);
    expect(missingLabels(fields)).toEqual([]);
  });

  it("covers every generated screen projection field", () => {
    const fields = projectionFields();
    expect(fields.size).toBe(289);
    expect(missingLabels(fields)).toEqual([]);
  });

  it("covers every generated operation-sample response field", () => {
    const fields = operationSampleFields();
    expect(fields.size).toBe(786);
    expect(missingLabels(fields)).toEqual([]);
  });

  it("covers every generated and handwritten mock response field", () => {
    const fields = mockResponseFields();
    expect(fields.size).toBe(921);
    expect(missingLabels(fields)).toEqual([]);
  });

  it("has no duplicate keys or generic labels", () => {
    const declaredCount = FIELD_LABEL_GROUPS.reduce(
      (count, group) => count + Object.keys(group).length,
      0,
    );
    expect(Object.keys(FIELD_LABELS)).toHaveLength(declaredCount);
    expect(duplicateSourceKeys()).toEqual([]);
    expect(
      Object.entries(FIELD_LABELS).filter(
        ([name, label]) =>
          !label.trim() || label === name || label === "확인 항목",
      ),
    ).toEqual([]);
    expect(
      Object.entries(FIELD_LABELS).filter(([, label]) =>
        /[A-Za-z]/u.test(
          label.replaceAll("SHA-256", "").replaceAll("Base64", ""),
        ),
      ),
    ).toEqual([]);
  });

  it("pins the supervisor-required Korean labels", () => {
    expect({
      partyName: FIELD_LABELS.partyName,
      whyMaterial: FIELD_LABELS.whyMaterial,
      asOf: FIELD_LABELS.asOf,
      publicMessage: FIELD_LABELS.publicMessage,
    }).toEqual({
      partyName: "당사자명",
      whyMaterial: "중요한 이유",
      asOf: "기준 시각",
      publicMessage: "공개 안내",
    });
  });

  it("fails closed for an unregistered field", () => {
    expect(() => fieldLabel("unregisteredFieldForClosureTest")).toThrowError(
      "한국어 필드 라벨 계약 누락: unregisteredFieldForClosureTest",
    );
    expect(() => explicitKoreanContextLabel("why Material")).toThrowError(
      "한국어 문맥 라벨 계약 위반: why Material",
    );
  });
});
