import { sendRequest } from "../lib/api";

export async function imagePull(...args: string[]) {
  let reference: string | undefined;
  let name: string | undefined;
  let username: string | undefined;
  let password: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--name" && i + 1 < args.length) {
      name = args[++i];
    } else if (args[i] === "--username" && i + 1 < args.length) {
      username = args[++i];
    } else if (args[i] === "--password" && i + 1 < args.length) {
      password = args[++i];
    } else if (!reference) {
      reference = args[i];
    }
  }

  if (!reference) {
    console.error("Usage: phantom pull <registry/namespace:tag> [--name <localName>]");
    console.error("  --name <name>        Local image name (default: derived from reference)");
    console.error("  --username <user>     Registry username");
    console.error("  --password <pass>     Registry password");
    process.exit(1);
  }

  const params: Record<string, any> = { reference };
  if (name) params.name = name;
  if (username) params.username = username;
  if (password) params.password = password;

  const response = await sendRequest({ method: "images.pull", params });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Pulling image from ${reference}...`);
  console.log("Use 'phantom images' to check progress.");
}
