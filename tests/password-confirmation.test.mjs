import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { runInNewContext } from "node:vm";
const source = await readFile("app/customer.js", "utf8");
const fn = source.slice(
  source.indexOf("async function submitPassword(form)"),
  source.indexOf("\nfunction forgotPassword()"),
);
test("password mismatch and invalid form cannot update credentials", async () => {
  for (const valid of [true, false]) {
    let calls = 0, status;
    const context = {
      document: {
        getElementById: (id) => ({
          value: id === "new-password" ? "password-one" : "password-two",
        }),
      },
      formStatus: (message) => status = message,
      sb: { auth: { updateUser: () => calls++ } },
    };
    runInNewContext(fn, context);
    await context.submitPassword({ reportValidity: () => valid });
    assert.equal(calls, 0);
    if (valid) assert.match(status, /do not match/);
  }
});
test("matching password updates through authenticated provider and restores button", async () => {
  let payload, closed = false;
  const busyStates = [];
  const context = {
    document: {
      getElementById: (id) =>
        id === "customer-dialog"
          ? { close: () => closed = true }
          : { value: "matching-password" },
    },
    busy: (_button, state) => busyStates.push(state),
    showToast: () => {},
    formStatus: () => {},
    sb: {
      auth: {
        updateUser: async (input) => {
          payload = input;
          return { error: null };
        },
      },
    },
  };
  runInNewContext(fn, context);
  await context.submitPassword({
    reportValidity: () => true,
    querySelector: () => ({}),
  });
  assert.equal(payload.password, "matching-password");
  assert.equal(closed, true);
  assert.deepEqual(busyStates, [true, false]);
});
