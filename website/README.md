# website (placeholder on the `windows` branch)

The Fanficly website lives in `website/` on `main`, and the Vercel project
builds from that folder. This branch has no site, so this placeholder exists
only so Vercel finds its Root Directory; `ignoreCommand: "exit 0"` then skips
the build, and pull requests to `windows` show the deployment as skipped
instead of failing. Don't add site files here.
