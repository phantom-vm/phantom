// A recipe is the account of what is inside an image, so the parser's job is
// as much to refuse a wrong one as to read a right one: a misspelled key that
// is quietly ignored turns the file into a false account, and a missing script
// found an hour into a build costs an hour.
//
//   bun test

import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadRecipe, parseRecipe, resolveAgainstRecipe } from "./recipe";

const minimal = `
schema: 1
name: xcode-26-6
from: tahoe-base
steps:
  - name: xcode
    script: ../provision/install-xcode.sh
`;

/// The message is the feature — assert on what it says, not that it threw.
function refusal(source: string, path = "recipe.yaml"): string {
  try {
    parseRecipe(source, path);
  } catch (err) {
    return (err as Error).message;
  }
  throw new Error("expected the recipe to be refused");
}

describe("a recipe that is one", () => {
  test("reads name, base and steps", () => {
    const recipe = parseRecipe(minimal, "recipe.yaml");
    expect(recipe.name).toBe("xcode-26-6");
    expect(recipe.from).toBe("tahoe-base");
    expect(recipe.steps).toHaveLength(1);
    expect(recipe.steps[0]!.script).toBe("../provision/install-xcode.sh");
    // Kept verbatim: the image records the file it was built from.
    expect(recipe.source).toBe(minimal);
  });

  test("a step's defaults are a half-hour and no assertion", () => {
    const step = parseRecipe(minimal, "recipe.yaml").steps[0]!;
    expect(step.timeoutMs).toBe(30 * 60_000);
    expect(step.env).toEqual({});
  });

  test("timeouts come in seconds, minutes and hours", () => {
    const withTimeout = (t: string) =>
      parseRecipe(`${minimal}    timeout: ${t}\n`, "recipe.yaml").steps[0]!.timeoutMs;
    expect(withTimeout("90s")).toBe(90_000);
    expect(withTimeout("15m")).toBe(900_000);
    expect(withTimeout("4h")).toBe(4 * 3600_000);
  });

  test("env values are strings, whatever YAML made of them", () => {
    const recipe = parseRecipe(
      `${minimal}    env:\n      RUNNER_VERSION: v18.11.2\n      RETRIES: 3\n`,
      "recipe.yaml"
    );
    expect(recipe.steps[0]!.env).toEqual({ RUNNER_VERSION: "v18.11.2", RETRIES: "3" });
  });

  test("a served file and the ${serve} that uses it", () => {
    const recipe = parseRecipe(
      `${minimal}    serve: ./Xcode.xip\n    env:\n      XCODE_SRC: \${serve}\n`,
      "recipe.yaml"
    );
    expect(recipe.steps[0]!.serve).toBe("./Xcode.xip");
    expect(recipe.steps[0]!.env.XCODE_SRC).toBe("${serve}");
  });
});

describe("a recipe that is not", () => {
  test("names the file it is complaining about", () => {
    expect(refusal("schema: 1\n", "recipes/x.yaml")).toStartWith("recipes/x.yaml:");
  });

  // A step's verdict is its exit code. There is no key for "must print X" —
  // asserting more than "the script ran" is a step that greps for it.
  test("there is no expect key", () => {
    expect(refusal(`${minimal}    expect: XCODE_INSTALL_DONE\n`)).toContain("unknown key 'expect'");
  });

  test("a misspelled key is an error, not a shrug", () => {
    expect(refusal(`${minimal}\ndescriptoin: oops\n`)).toContain("unknown key 'descriptoin'");
    expect(refusal(minimal.replace("script:", "scripts:"))).toContain("unknown key 'scripts'");
  });

  test("the schema has to be one this phantom understands", () => {
    expect(refusal(minimal.replace("schema: 1", "schema: 2"))).toContain("unsupported schema 2");
    expect(refusal(minimal.replace("schema: 1\n", ""))).toContain("missing 'schema: 1'");
  });

  test("the name has to be one an image can have", () => {
    expect(refusal(minimal.replace("xcode-26-6", "xcode 26.6"))).toContain("name must be letters");
    expect(refusal(minimal.replace("from: tahoe-base", "from: ../etc"))).toContain(
      "from must name the base image"
    );
  });

  test("no steps means the image is its base", () => {
    expect(refusal("schema: 1\nname: x\nfrom: y\nsteps: []\n")).toContain("non-empty list");
  });

  test("a step does one thing, and says which", () => {
    expect(refusal(`${minimal}    run: echo hi\n`)).toContain("either script or run, not both");
    expect(refusal("schema: 1\nname: x\nfrom: y\nsteps:\n  - name: bare\n")).toContain(
      "needs a script (a file) or a run"
    );
  });

  test("steps are named, and named apart", () => {
    expect(refusal("schema: 1\nname: x\nfrom: y\nsteps:\n  - run: echo hi\n")).toContain(
      "step 1 needs a name"
    );
    expect(refusal(`${minimal}  - name: xcode\n    run: echo again\n`)).toContain(
      "duplicate step name 'xcode'"
    );
  });

  test("the error carries the step's name", () => {
    expect(refusal(`${minimal}    env:\n        not a var: 1\n`)).toContain("step 'xcode'");
  });

  test("a served file nothing reads, and a ${serve} with nothing to serve", () => {
    expect(refusal(`${minimal}    serve: ./Xcode.xip\n`)).toContain("nothing uses ${serve}");
    expect(
      refusal("schema: 1\nname: x\nfrom: y\nsteps:\n  - name: s\n    run: curl ${serve}\n")
    ).toContain("no file is served");
  });

  test("YAML that is not YAML", () => {
    expect(refusal("steps: [\n")).toContain("not valid YAML");
  });
});

describe("paths", () => {
  test("resolve against the recipe, not the shell's directory", () => {
    expect(resolveAgainstRecipe("/repo/recipes/x.yaml", "../provision/install.sh")).toBe(
      "/repo/provision/install.sh"
    );
    expect(resolveAgainstRecipe("/repo/recipes/x.yaml", "/abs/install.sh")).toBe("/abs/install.sh");
    expect(resolveAgainstRecipe("/repo/recipes/x.yaml", "~/Downloads/Xcode.xip")).toStartWith(
      `${process.env.HOME}/Downloads`
    );
  });

  test("a missing script is found before the build, and says where it looked", async () => {
    const dir = mkdtempSync(join(tmpdir(), "phantom-recipe-"));
    writeFileSync(join(dir, "r.yaml"), minimal);
    await expect(loadRecipe(join(dir, "r.yaml"))).rejects.toThrow(/script not found.*looked in/s);
  });

  test("a recipe whose files are all there loads", async () => {
    const dir = mkdtempSync(join(tmpdir(), "phantom-recipe-"));
    mkdirSync(join(dir, "provision"));
    writeFileSync(join(dir, "provision", "install-xcode.sh"), "echo hi\n");
    writeFileSync(join(dir, "r.yaml"), minimal.replace("../provision", "provision"));
    const recipe = await loadRecipe(join(dir, "r.yaml"));
    expect(recipe.steps[0]!.script).toBe("provision/install-xcode.sh");
  });
});
