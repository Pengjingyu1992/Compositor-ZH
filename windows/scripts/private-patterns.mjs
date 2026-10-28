// Token formats are case-sensitive. In particular, AWS access IDs contain only
// uppercase letters and digits; folding case mistakes ordinary Base64 for a key.
export const sensitive=[
  /(?:\/(?:Users|home)\/[^/\\\s]+(?:\/|$)|\/root(?:\/|$)|[A-Z]:\\Users\\[^\\\s]+(?:\\|$))/i,
  /(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{35}|(?:AKIA|ASIA)[0-9A-Z]{16})/,
  /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/,
  /(?:api[_-]?key|access[_-]?token|password|aws[_-]?(?:secret[_-]?access[_-]?key|session[_-]?token))["']?\s*[:=]\s*["'][A-Za-z0-9_+/=\-]{20,}["']/i
];
