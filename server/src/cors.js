export const CORS_ALLOWED_HEADERS = [
  "Content-Type",
  "Accept",
  "X-Wenxiang-Key",
  "ngrok-skip-browser-warning",
];

export const corsOptions = {
  origin: true,
  methods: ["GET", "HEAD", "PUT", "PATCH", "POST", "DELETE", "OPTIONS"],
  allowedHeaders: CORS_ALLOWED_HEADERS,
  optionsSuccessStatus: 204,
  maxAge: 86400,
};
