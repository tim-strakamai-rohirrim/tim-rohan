# Git worktrees for rohan_api and rohan_ui

Use one clone per repo as the “main” worktree and add extra worktrees for feature branches so you can work on multiple features at once without stashing or switching branches.

## Layout (suggested)

Keep your current folders as the **primary** worktree (e.g. `main` or `develop`), and add **feature worktrees** as siblings:

```
rohan/
├── rohan_api-parent/
│   ├── rohan_api/              ← primary worktree (e.g. main)
│   ├── rohan_api-PRCR-751/     ← worktree for feature/PRCR-751
│   └── rohan_api-other-feature/
├── rohan_ui-parent/
│   ├── rohan_ui/               ← primary worktree
│   ├── rohan_ui-PRCR-751/
│   └── rohan_ui-other-feature/
└── ...
```

## Commands

### rohan_api

From the **primary** clone (`rohan_api-parent/rohan_api`):

```bash
cd /Users/tim/Documents/code/rohan/rohan_api-parent/rohan_api

# Create a worktree for a new branch
git worktree add ../rohan_api-PRCR-1161 -b tim/PRCR-1161

# Or for an existing branch
git worktree add ../rohan_api-PRCR-751 tim/PRCR-751

# List worktrees
git worktree list

# Remove when done (from primary repo, after deleting or not using the worktree)
git worktree remove ../rohan_api-PRCR-1161
# Or if the directory is already deleted:
git worktree prune
```

### rohan_ui

Same idea from the UI repo:

```bash
cd /Users/tim/Documents/code/rohan/rohan_ui-parent/rohan_ui

git worktree add ../rohan_ui-PRCR-751 -b feature/PRCR-751
git worktree list
```

## Cursor / VS Code

- **One window per feature**: **File → Open Folder** and open the worktree folder (e.g. `rohan_api-parent/rohan_api-PRCR-751`). Use separate windows for “main” vs “PRCR-751” etc.
- **One window, multiple roots**: **File → Add Folder to Workspace** and add both the api and ui worktrees for that feature, then **File → Save Workspace As** (e.g. `prcr-751-worktrees.code-workspace`).
- **Switching**: Open the workspace file or folder for the feature you’re working on; each worktree has its own branch and files.

Example multi-root workspace for a single feature (save as e.g. `prcr-751-worktrees.code-workspace` in `rohan/`):

```json
{
  "folders": [
    {
      "name": "rohan_api (PRCR-751)",
      "path": "rohan_api-parent/rohan_api-PRCR-751"
    },
    {
      "name": "rohan_ui (PRCR-751)",
      "path": "rohan_ui-parent/rohan_ui-PRCR-751"
    }
  ],
  "settings": {}
}
```

## Tips

1. **Primary worktree**: Prefer keeping `main` or `develop` in the existing `rohan_api` and `rohan_ui` folders so your current workflow stays the same.
2. **Same branch in two worktrees**: Git does not allow the same branch to be checked out in two worktrees. Use different branches (e.g. `feature/PRCR-751` and `feature/other`).
3. **Fetch once**: All worktrees share the same Git object store; run `git fetch` in the primary clone and branches are visible in every worktree.
4. **Cleanup**: `git worktree remove <path>` from the primary repo, or delete the worktree directory and run `git worktree prune`.
