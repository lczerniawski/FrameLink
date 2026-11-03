# Releases

The [release workflow](.github/workflows/release.yml) builds the IPA, publishes a GitHub Release, and updates the AltStore-compatible feed when you push a version tag.

## Initial setup

1. In **Settings → Pages → Build and deployment → Source**, select **GitHub Actions**.
2. If the `github-pages` environment restricts deployments, allow tags matching `v*` under **Settings → Environments → github-pages**.
3. Commit and push the workflow, `distribution/source.json`, release scripts, and tests to `main`. No Apple credentials or signing certificates are needed.

Add this source in AltStore Classic or SideStore:

```text
https://lczerniawski.github.io/FrameLink/source.json
```

## New release

1. In Xcode, increment the app's **Version** and **Build**. Edit `distribution/source.json` if the listing description needs to change.
2. Commit and push to `main`, then tag that commit. The tag must match the app version: version `1.1` requires `v1.1`.

   ```sh
   git tag v1.1
   git push origin v1.1
   ```

   For the first release, use `v1.0` with the current version `1.0`.

3. Check **Actions → Release Frame Link**. All three jobs (`build`, `publish`, `deploy`) must pass. Approve the deployment if the environment requires it.
4. Check that the feed lists the new version, then test installation and refresh on an iPhone.

Use a new version and tag for each release; keep published assets unchanged. If only Pages deployment fails after the Release is published, fix the deployment issue and select **Re-run failed jobs** instead of rebuilding the IPA.
