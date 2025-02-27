## Pull Requests

All changes, no matter how trivial, must be done via pull request. Commits
should never be made directly on the `main` branch. Prefer rebasing over
merging `main` into your PR branch to update it and resolve conflicts.

## Building And Running Locally

1. `git clone https://github.com/MobileNativeFoundation/rules_xcodeproj.git`
1. `cd rules_xcodeproj`
1. `bazel run //tools/generators/legacy:xcodeproj` to generate an Xcode project
and develop in Xcode, or just open the directory in your favourite text
editor.
1. Build with Xcode:
    1. Select the `generator` scheme to compile the executable.
    1. Select the `tests` scheme to run the tests.
1. Build with Bazel:
    1. `bazel build //tools/generators/legacy:generator` to compile the executable.
    1. `bazel test //tools/generators/legacy/test/...` to run the tests.

## Developing

Feel free to volunteer by picking up any bug from the list of
[GitHub issues](https://github.com/MobileNativeFoundation/rules_xcodeproj/issues).
If you find a new bug or would like to work on a new feature,
create a new GitHub issue to better describe your intentions. We are happy
to guide contributors with an implementation through discussions if needed.

You can test your changes in the example projects by generating their
projects with `bazel run //examples/cc:xcodeproj`. You might need to `cd`
into the directory if the example app is in a separate `WORKSPACE` with
`cd examples/integration; bazel run //:xcodeproj`.

You can run the internal tests as well:
`bazel test //test/internal/xcschemes:all`

You can even test your changes in a separate project living outside this
repo by overriding the module or repository in your `.bazelrc`.
```
# With bzlmod:
build --override_module=rules_xcodeproj=/path/to/rules_xcodeproj
# Without bzlmod:
build --override_repository=rules_xcodeproj=/path/to/rules_xcodeproj
```
It's important to add it to the `.bazelrc` instead of passing it as a
flag to ensure all invocations will use the same configuration.

## Test fixtures

While developing, you might need to regenerate the test fixtures.
You can do so with `./test/update_all_fixtures.sh`.

All of the test fixture projects aren't buildable, because we use empty files in
place of things that are the same in every project. If you need to verify
anything in those projects, regenerate them locally.

## Updating docs

Run `./docs/update_docs.sh` to generate to documentation based on the comments.

## Linting and formatting

Before submitting your PR you should run the linter and formatter to
make sure everything if formatted properly in your bazel files

`bazel run //:buildifier.fix`

you can run `bazel run //:buildifier.check` to make sure your formatting
is correct.
