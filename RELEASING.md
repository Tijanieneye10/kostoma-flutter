# Releasing

For whoever publishes a new version. Do the steps in order.

1. **Decide the number.** Read [VERSIONING.md](VERSIONING.md). While the version is 0.x: a fix is a new PATCH, anything else is a new MINOR.
2. **Set it in three places:** `version:` in `pubspec.yaml`, `kostomaSdkVersion` in `lib/src/version.dart`, and a new section at the top of `CHANGELOG.md` saying what changed in words a user of the SDK would recognise. `test/version_test.dart` fails if they disagree.
3. **If what the SDK sends has changed,** `test/compat_test.dart` fails. Update `compat/requests.json` to what is now sent, and set its `version`. If nothing on the wire changed, only its `version` changes.
4. **Run the checks:** `dart format .`, `flutter analyze`, `flutter test`.
5. **Commit, and open a pull request.** Merge it once CI passes.
6. **Record the version in the Kostoma repository.** Copy `compat/requests.json` to `tests/Fixtures/sdks/flutter/<version>.json` there, and run its tests. That is what holds the API to this version from now on. If that test fails, the API does not accept what this version sends: fix that before tagging, not after.
7. **Tag the merged commit and push the tag:** `git tag v<version> && git push origin v<version>`. The release workflow checks the tag against `pubspec.yaml`, runs the tests and creates the GitHub release from the changelog.

Never move or delete a tag that has been pushed. Someone's `pubspec.lock` may point at it.

## When the API changes

A change to the Kostoma API starts in the Kostoma repository, in `contracts/v1/`. Its test over `tests/Fixtures/sdks/flutter/` says at once whether any released SDK version is affected.

- **It passes:** the change is one the SDK does not notice. To use a new field or endpoint from the SDK, add it here and release a MINOR.
- **It fails:** the change would break an installed SDK, and must not ship as it is. Make it additive, or make it a new API version.
