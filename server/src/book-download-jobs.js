import { randomUUID } from "node:crypto";
import { downloadBookFromUrl } from "./books-search.js";

/** 大书 / 慢镜像落盘可能超过数分钟 */
export const BOOK_DOWNLOAD_TIMEOUT_MS = 20 * 60 * 1000;
const JOB_TTL_MS = 60 * 60 * 1000;
const MAX_JOBS = 48;

/** @type {Map<string, BookDownloadJob>} */
const jobs = new Map();

function pruneOldJobs() {
  const now = Date.now();
  for (const [id, job] of jobs) {
    if (now - job.createdAt > JOB_TTL_MS) jobs.delete(id);
  }
}

/**
 * @param {{ url: string, title?: string, cookieHeader?: string, referer?: string, workspaceRoot: string }} opts
 * @returns {string} jobId
 */
export function startBookDownloadJob(opts) {
  pruneOldJobs();
  if (jobs.size >= MAX_JOBS) {
    const err = new Error("下载任务过多，请稍后再试");
    err.status = 429;
    err.code = "download_busy";
    throw err;
  }
  const id = randomUUID();
  const job = {
    id,
    status: "pending",
    createdAt: Date.now(),
    url: String(opts.url || "").trim(),
    title: String(opts.title || "").trim(),
    cookieHeader: String(opts.cookieHeader || "").trim(),
    referer: String(opts.referer || "").trim(),
    progress: { phase: "queued", bytesReceived: 0, bytesTotal: null },
  };
  jobs.set(id, job);
  void runBookDownloadJob(job, opts.workspaceRoot);
  return id;
}

/** @param {string} jobId */
export function getBookDownloadJob(jobId) {
  if (!jobId) return null;
  return jobs.get(jobId) || null;
}

/** @param {BookDownloadJob} job */
async function runBookDownloadJob(job, workspaceRoot) {
  try {
    const result = await downloadBookFromUrl(job.url, {
      workspaceRoot,
      suggestedTitle: job.title,
      cookieHeader: job.cookieHeader,
      referer: job.referer,
      signal: AbortSignal.timeout(BOOK_DOWNLOAD_TIMEOUT_MS),
      onProgress: (p) => {
        job.progress = {
          phase: p.phase || job.progress?.phase || "downloading",
          bytesReceived: p.bytesReceived ?? job.progress?.bytesReceived ?? 0,
          bytesTotal:
            p.bytesTotal !== undefined ? p.bytesTotal : job.progress?.bytesTotal ?? null,
        };
      },
    });
    job.status = "done";
    job.result = result;
    job.finishedAt = Date.now();
  } catch (err) {
    job.status = "failed";
    job.error = err?.message || String(err);
    job.code = err?.code || "download_failed";
    job.httpStatus = err?.status || 502;
    job.debug = err?.debug || null;
    job.finishedAt = Date.now();
  }
}

/**
 * @typedef {object} BookDownloadJob
 * @property {string} id
 * @property {"pending"|"done"|"failed"} status
 * @property {number} createdAt
 * @property {number} [finishedAt]
 * @property {string} url
 * @property {string} title
 * @property {string} cookieHeader
 * @property {object} [result]
 * @property {string} [error]
 * @property {string} [code]
 * @property {number} [httpStatus]
 * @property {{ phase: string, bytesReceived: number, bytesTotal: number|null }} [progress]
 * @property {string} [referer]
 * @property {object} [debug]
 */
