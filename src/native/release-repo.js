// Single source of truth for the GitHub repository that serves releases, in-app
// updates and remote announcements. Forks must change only this file (plus the
// matching `build.publish` in package.json and build/app-update.yml, which are
// checked by scripts/check-release-repo.cjs).
const OWNER = 'shuiandy';
const REPO = 'hongguo-drama';
const SLUG = `${OWNER}/${REPO}`;

module.exports = {
  OWNER,
  REPO,
  SLUG,
  RELEASES_URL: `https://github.com/${SLUG}/releases`,
  LATEST_RELEASE_URL: `https://github.com/${SLUG}/releases/latest`,
  LATEST_RELEASE_API: `https://api.github.com/repos/${SLUG}/releases/latest`,
  ISSUES_URL: `https://github.com/${SLUG}/issues`,
  RAW_MAIN_URL: `https://raw.githubusercontent.com/${SLUG}/main`,
};
