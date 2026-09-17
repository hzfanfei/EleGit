const GITHUB_API = "https://api.github.com";
const GITHUB_LOGIN = "https://github.com/login";

function headers(token) {
  return {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "wenxiang-local-server",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
}

async function readGithub(res) {
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { message: text };
  }
  if (!res.ok) {
    const message = body?.message || `GitHub HTTP ${res.status}`;
    const err = new Error(message);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

export async function githubGet(token, pathname, query = {}) {
  const url = new URL(pathname.startsWith("http") ? pathname : `${GITHUB_API}${pathname}`);
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== "") url.searchParams.set(key, String(value));
  }
  const res = await fetch(url, { headers: headers(token) });
  return readGithub(res);
}

export async function verifyToken(token) {
  const user = await githubGet(token, "/user");
  return {
    login: user.login,
    name: user.name || "",
    avatarUrl: user.avatar_url || "",
  };
}

export async function listRepos(token, q = "") {
  const repos = await githubGet(token, "/user/repos", {
    per_page: 80,
    sort: "updated",
    affiliation: "owner,collaborator,organization_member",
  });
  const mine = (repos || []).map(summarizeRepo);
  const needle = q.trim().toLowerCase();
  if (!needle) return mine;

  const filtered = mine.filter((repo) =>
    `${repo.fullName} ${repo.description}`.toLowerCase().includes(needle),
  );
  if (filtered.length) return filtered;

  const data = await githubGet(token, "/search/repositories", {
    q: needle,
    per_page: 20,
    sort: "updated",
  });
  return (data.items || []).map(summarizeRepo);
}

function summarizeRepo(repo) {
  return {
    id: repo.id,
    owner: repo.owner?.login || "",
    name: repo.name,
    fullName: repo.full_name,
    description: repo.description || "",
    private: Boolean(repo.private),
    defaultBranch: repo.default_branch || "main",
    pushedAt: repo.pushed_at,
    htmlUrl: repo.html_url,
    language: repo.language || "",
    openIssues: repo.open_issues_count ?? 0,
    stargazers: repo.stargazers_count ?? 0,
  };
}

export async function repoProgress(token, owner, repo) {
  const [meta, commits, pulls, issues] = await Promise.all([
    githubGet(token, `/repos/${owner}/${repo}`),
    githubGet(token, `/repos/${owner}/${repo}/commits`, { per_page: 20 }).catch(() => []),
    githubGet(token, `/repos/${owner}/${repo}/pulls`, {
      state: "open",
      per_page: 20,
      sort: "updated",
    }).catch(() => []),
    githubGet(token, `/repos/${owner}/${repo}/issues`, {
      state: "open",
      per_page: 20,
      sort: "updated",
    }).catch(() => []),
  ]);

  const commitList = (commits || []).map((c) => ({
    sha: c.sha?.slice(0, 7),
    message: (c.commit?.message || "").split("\n")[0],
    author: c.commit?.author?.name || c.author?.login || "",
    date: c.commit?.author?.date || "",
  }));

  const pullList = (pulls || []).map((p) => ({
    number: p.number,
    title: p.title,
    user: p.user?.login || "",
    updatedAt: p.updated_at,
    draft: Boolean(p.draft),
  }));

  const issueList = (issues || [])
    .filter((i) => !i.pull_request)
    .map((i) => ({
      number: i.number,
      title: i.title,
      user: i.user?.login || "",
      updatedAt: i.updated_at,
    }));

  return {
    repo: summarizeRepo(meta),
    commits: commitList,
    pulls: pullList,
    issues: issueList,
  };
}

/** Placeholder progress when GitHub API is deferred (chat fast path). */
export function emptyRepoProgress(owner, repo, defaultBranch = "main") {
  return {
    repo: {
      id: 0,
      owner,
      name: repo,
      fullName: `${owner}/${repo}`,
      description: "",
      private: false,
      defaultBranch,
      pushedAt: "",
      htmlUrl: `https://github.com/${owner}/${repo}`,
      language: "",
      openIssues: 0,
      stargazers: 0,
    },
    commits: [],
    pulls: [],
    issues: [],
  };
}

export async function startDeviceFlow(clientId) {
  if (!clientId) {
    const err = new Error(
      "GitHub device flow needs GITHUB_CLIENT_ID (OAuth App). Use a PAT instead.",
    );
    err.status = 400;
    throw err;
  }
  const res = await fetch(`${GITHUB_LOGIN}/device/code`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ client_id: clientId, scope: "repo read:user" }),
  });
  return readGithub(res);
}

export async function pollDeviceFlow(clientId, deviceCode) {
  const res = await fetch(`${GITHUB_LOGIN}/oauth/access_token`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      client_id: clientId,
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    }),
  });
  const body = await readGithub(res);
  if (body.error) {
    const err = new Error(body.error_description || body.error);
    err.status = body.error === "authorization_pending" || body.error === "slow_down" ? 202 : 400;
    err.code = body.error;
    throw err;
  }
  return body;
}

export function formatProgressContext(progress) {
  const lines = [
    `Repository: ${progress.repo.fullName}`,
    `Description: ${progress.repo.description || "(none)"}`,
    `Default branch: ${progress.repo.defaultBranch}`,
    `Last push: ${progress.repo.pushedAt || "unknown"}`,
    `Language: ${progress.repo.language || "unknown"}`,
    `Open issues (GitHub count): ${progress.repo.openIssues}`,
    "",
    "Recent commits:",
  ];
  if (!progress.commits.length) {
    lines.push("- (none visible)");
  } else {
    for (const c of progress.commits) {
      lines.push(`- ${c.date} ${c.sha} ${c.author}: ${c.message}`);
    }
  }
  lines.push("", "Open pull requests:");
  if (!progress.pulls.length) {
    lines.push("- (none)");
  } else {
    for (const p of progress.pulls) {
      lines.push(`- #${p.number} ${p.draft ? "[draft] " : ""}${p.title} (${p.user}, ${p.updatedAt})`);
    }
  }
  lines.push("", "Open issues:");
  if (!progress.issues.length) {
    lines.push("- (none)");
  } else {
    for (const i of progress.issues) {
      lines.push(`- #${i.number} ${i.title} (${i.user}, ${i.updatedAt})`);
    }
  }
  return lines.join("\n");
}
