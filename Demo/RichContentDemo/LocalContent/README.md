# LocalContent

Drop your own test content here: an email body, an API response, notes.
Each `.html`, `.md` or `.txt` file shows up in the demo app as

- a note in **Notes** (added on the next launch), and
- a sample in **Viewer**,

both titled with the file name. The contents are passed unchanged to
`.auto`, so a file can hold HTML, Markdown, a mix of both, or HTML still
JSON-escaped from an API (`\"`, `\r\n`, ` `). Empty files are skipped.

## Keeping your content private

Git ignores every file in this folder except this README and the empty
`htmlcontent.html`. Add as many files as you like (`welcome.md`,
`invoice.html`, …); they stay on your machine.

`htmlcontent.html` is tracked so the folder exists after a clone. Before you
paste into it, tell git to ignore your local changes to it:

```bash
git update-index --skip-worktree Demo/RichContentDemo/LocalContent/htmlcontent.html
```

Undo with `--no-skip-worktree`.

## Notes

- Notes are created once per file name. To re-import a changed file, delete
  its note and use "…" → Restore Sample Notes, or rename the file.
- Viewer always shows the file's current contents.
