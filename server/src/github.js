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

async function githubPost(token, pathname, body) {
  const url = new URL(pathname.startsWith("http") ? pathname : `${GITHUB_API}${pathname}`);
  const res = await fetch(url, {
    method: "POST",
    headers: { ...headers(token), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return readGithub(res);
}

const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i;

export function validateNewRepoName(raw) {
  const name = String(raw || "").trim();
  if (!name) {
    const err = new Error("请填写仓库名");
    err.status = 400;
    err.code = "repo_name_required";
    throw err;
  }
  const bad =
    name.length > 100 ||
    name.startsWith(".") ||
    name.startsWith("-") ||
    name.endsWith(".") ||
    name.includes("..") ||
    /\.git$/i.test(name) ||
    WINDOWS_RESERVED.test(name) ||
    /[\s\\/?#%*:|"<>]/.test(name) ||
    /[\u0000-\u001f]/.test(name);
  if (bad) {
    const err = new Error("仓库名请用字母、数字或中文，可加点、下划线和连字符");
    err.status = 400;
    err.code = "repo_name_invalid";
    throw err;
  }
  return name;
}

export function validateNewRepoDescription(raw) {
  const description = String(raw || "").trim();
  if (description.length > 350) {
    const err = new Error("简介最多 350 个字");
    err.status = 400;
    err.code = "repo_description_invalid";
    throw err;
  }
  return description;
}

function mapCreateRepoError(err) {
  const errors = Array.isArray(err.body?.errors) ? err.body.errors : [];
  const detail = errors.map((item) => String(item.message || "")).join(" ");
  const blob = `${err.message || ""} ${detail}`.toLowerCase();
  if (blob.includes("already exists")) {
    const mapped = new Error("这个仓库名已经有了，换一个名字");
    mapped.status = 409;
    mapped.code = "repo_exists";
    return mapped;
  }
  if (err.status === 401 || err.status === 403) {
    const mapped = new Error("GitHub 没有创建仓库的权限。请重新登录，并允许仓库读写。");
    mapped.status = err.status;
    mapped.code = "repo_forbidden";
    return mapped;
  }
  if (err.status === 422) {
    const mapped = new Error("GitHub 没有接受这个仓库名");
    mapped.status = 422;
    mapped.code = "repo_rejected";
    return mapped;
  }
  return err;
}

/** Create an empty repo on the signed-in user's GitHub account. */
export async function createUserRepo(token, input = {}) {
  const name = validateNewRepoName(input.name);
  const description = validateNewRepoDescription(input.description);
  const isPrivate = !(input.private === false || input.private === "false");
  try {
    const repo = await githubPost(token, "/user/repos", {
      name,
      description,
      private: isPrivate,
      auto_init: true,
    });
    return summarizeRepo(repo);
  } catch (err) {
    throw mapCreateRepoError(err);
  }
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
