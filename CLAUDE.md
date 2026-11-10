# Louder

## After every change

Without asking, once a change is made and builds/tests pass:

1. Commit it (on a branch if you made one), merge into `main`, and push `origin main`.
2. Delete the old branch / worktree.
3. Compile, install and relaunch the app: `./build.sh install` (builds release, replaces `/Applications/Louder.app`, relaunches it).
