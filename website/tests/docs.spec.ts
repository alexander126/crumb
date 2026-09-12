import { test, expect } from "@playwright/test";

test("three quickstarts lead to rendered content without horizontal overflow", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toContainText(
    "Useful reports.",
  );
  await expect(page.locator(".platform-link")).toHaveCount(3);
  for (const [slug, title] of [
    ["react-native", "React Native"],
    ["ios", "iOS"],
    ["android", "Android"],
  ]) {
    await page.goto(`/docs/quickstarts/${slug}/`);
    await expect(
      page.getByRole("heading", { level: 1, name: title, exact: true }),
    ).toBeVisible();
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
  }
  expect(errors).toEqual([]);
});

test("Expo and bare paths share one quickstart and keyboard tabs work", async ({
  page,
}) => {
  await page.goto("/docs/quickstarts/react-native/");
  const expo = page.getByRole("tab", { name: "Expo", exact: true });
  await expo.scrollIntoViewIfNeeded();
  await expect(expo).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("tabpanel")).toContainText(
    "expo-build-properties",
  );
  await expo.focus();
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("Enter");
  await expect(
    page.getByRole("tab", { name: "Bare React Native", exact: true }),
  ).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("tabpanel")).toContainText("npx pod-install");
  await expect(
    page.getByRole("heading", { name: /^3\. Configure Crumb once/ }),
  ).toBeVisible();
});

test("static search finds source maps and navigates to a result", async ({
  page,
}) => {
  await page.goto("/docs/");
  await page.keyboard.press("ControlOrMeta+k");
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await dialog
    .getByRole("textbox", { name: "Search", exact: true })
    .fill("source maps");
  await expect(
    dialog.getByRole("button", {
      name: "Documentation Build a better report Source maps",
      exact: true,
    }),
  ).toBeVisible();
  await dialog
    .getByRole("button", {
      name: "Documentation Build a better report Source maps",
      exact: true,
    })
    .click();
  await expect(page).toHaveURL(/\/docs\/guides\/source-maps\//);
  await expect(dialog).not.toBeVisible();
});

test("Markdown exports and static search are available without an application server", async ({
  request,
}) => {
  for (const path of [
    "/llms.txt",
    "/llms-full.txt",
    "/llms.mdx/docs/quickstarts/react-native/content.md",
  ]) {
    const response = await request.get(path);
    expect(response.ok()).toBe(true);
    expect(await response.text()).toContain("React Native");
  }
  const response = await request.get("/api/search");
  expect(response.ok()).toBe(true);
  expect(await response.json()).toHaveProperty("type");
});

test("code and page Markdown can be copied, including the hidden setup alternative", async ({
  page,
  context,
}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/docs/quickstarts/react-native/");
  await page
    .getByRole("button", { name: "Copy Text", exact: true })
    .first()
    .click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toContain("@crumbsdk/react-native@0.0.1-rc.3");
  await page
    .getByRole("button", { name: "Copy Markdown", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toContain("npx pod-install");
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toContain("expo-build-properties");
});

test("dark mode stays readable and missing pages remain 404s", async ({
  page,
}) => {
  await page.emulateMedia({ colorScheme: "dark", reducedMotion: "reduce" });
  await page.goto("/");
  await expect(page.locator("html")).toHaveClass(/dark/);
  expect(
    await page
      .locator("body")
      .evaluate((el) => getComputedStyle(el).backgroundColor),
  ).not.toBe("rgb(255, 255, 255)");
  const response = await page.goto("/docs/this-page-does-not-exist/");
  expect(response?.status()).toBe(404);
});
