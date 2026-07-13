import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { createClient } from "@hey-api/openapi-ts";

type ClientTarget = Readonly<{
  input: string;
  output: string;
}>;

const root = resolve(import.meta.dir, "..");
const targets: readonly ClientTarget[] = [
  {
    input: "specs/generated/public-api.openapi.json",
    output: "packages/api-client-public/src/generated",
  },
  {
    input: "specs/generated/control-api.openapi.json",
    output: "packages/api-client-control/src/generated",
  },
  {
    input: "specs/generated/submission-api.openapi.json",
    output: "packages/api-client-submission/src/generated",
  },
  {
    input: "specs/generated/identity-service-internal.openapi.json",
    output: "packages/api-client-identity-internal/src/generated",
  },
];

async function filesBelow(directory: string): Promise<readonly string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const path = join(directory, entry.name);
      return entry.isDirectory() ? filesBelow(path) : [path];
    }),
  );
  return nested.flat().sort();
}

async function assertTreesEqual(
  expected: string,
  actual: string,
): Promise<void> {
  const expectedFiles = (await filesBelow(expected)).map((path) =>
    relative(expected, path),
  );
  const actualFiles = (await filesBelow(actual)).map((path) =>
    relative(actual, path),
  );
  if (JSON.stringify(expectedFiles) !== JSON.stringify(actualFiles)) {
    throw new Error(`generated client file set differs: ${expected}`);
  }
  for (const file of expectedFiles) {
    const [left, right] = await Promise.all([
      readFile(join(expected, file)),
      readFile(join(actual, file)),
    ]);
    if (!left.equals(right)) {
      throw new Error(`generated client differs: ${join(expected, file)}`);
    }
  }
}

async function generate(target: ClientTarget, output: string): Promise<void> {
  await createClient({
    input: resolve(root, target.input),
    output,
    plugins: ["@hey-api/client-fetch", "@hey-api/typescript", "@hey-api/sdk"],
  });
  await normalizeGeneratedTypes(output);
}

async function normalizeGeneratedTypes(directory: string): Promise<void> {
  for (const path of await filesBelow(directory)) {
    if (!path.endsWith(".ts")) continue;
    const source = await readFile(path, "utf8");
    const normalized = source
      .replaceAll(
        "allowReserved?: boolean;",
        "allowReserved?: boolean | undefined;",
      )
      .replaceAll("event?: string;", "event?: string | undefined;")
      .replaceAll("id?: string;", "id?: string | undefined;")
      .replaceAll("map?: string;", "map?: string | undefined;")
      .replaceAll(
        "path?: Record<string, unknown>;",
        "path?: Record<string, unknown> | undefined;",
      )
      .replaceAll(
        "query?: Record<string, unknown>;",
        "query?: Record<string, unknown> | undefined;",
      )
      .replaceAll(
        "serializedBody?: string;",
        "serializedBody?: string | undefined;",
      )
      .replace(
        "        body: getValidRequestBody(opts),",
        "        ...(getValidRequestBody(opts) !== undefined ? { body: getValidRequestBody(opts) } : {}),",
      )
      .replace(
        "    return createSseClient({\n      ...opts,\n      body: opts.body as BodyInit | null | undefined,",
        "    const { body, ...sseOptions } = opts;\n    return createSseClient({\n      ...sseOptions,\n      ...(body !== undefined ? { body: body as BodyInit | null } : {}),",
      )
      .replace(
        "          body: options.serializedBody,",
        "          ...(options.serializedBody !== undefined ? { body: options.serializedBody } : {}),",
      )
      .replace(
        "      // TODO: we probably want to return error and improve types\n",
        "",
      );
    if (normalized !== source) await writeFile(path, normalized);
  }
}

const check = process.argv.includes("--check");
if (check) {
  const temporary = await mkdtemp(join(tmpdir(), "gurine-clients-"));
  try {
    for (const [index, target] of targets.entries()) {
      const candidate = join(temporary, String(index));
      await generate(target, candidate);
      await assertTreesEqual(resolve(root, target.output), candidate);
    }
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
} else {
  for (const target of targets) {
    await generate(target, resolve(root, target.output));
  }
}
