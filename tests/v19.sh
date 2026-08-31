#!/bin/bash
set -Eeuo pipefail
umask 077

result=${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}
db_password=${TKL_TEST_DB_PASS:?TKL_TEST_DB_PASS is required}
base=https://localhost
page=/tmp/tkl-laravel-page.$$
queue_marker=/tmp/tkl-laravel-queue.$$
policy=/tmp/tkl-laravel-policy.$$

cleanup() {
    rm -f -- "$page" "$queue_marker" "$policy"
    rm -f -- /var/www/laravel/app/Jobs/TurnKeyAcceptanceJob.php
}
trap cleanup EXIT
trap 'status=$?; printf "laravel_acceptance_failed_line=%s status=%s\n" "$LINENO" "$status" >&2; exit "$status"' ERR

systemctl --quiet is-active apache2.service mariadb.service postfix.service \
    cron.service multi-user.target
systemctl --quiet is-enabled apache2.service mariadb.service postfix.service \
    cron.service
apache2ctl -t
apache2ctl -M 2>/dev/null | grep -q ' rewrite_module '
grep -Fxq 'VERSION_CODENAME=trixie' /etc/os-release
grep -Eq '^turnkey-laravel-19\.0' /etc/turnkey_version

turnkey-composer --working-dir=/var/www/laravel validate \
    --no-check-publish --no-interaction
turnkey-composer --working-dir=/var/www/laravel check-platform-reqs --no-dev

framework_version=$(turnkey-artisan --version | awk '{print $3}')
[[ $framework_version == 13.* ]]
php_version=$(php --version | head -n 1)
[[ $php_version == 'PHP 8.4.'* ]]
turnkey-artisan about --only=environment >/dev/null
turnkey-artisan route:list --path=/ >/dev/null
turnkey-artisan migrate:status --no-interaction >/dev/null

curl --insecure --fail --silent --show-error "$base/" >"$page"
grep -Fq '<title>TurnKey Laravel</title>' "$page"
grep -Fq 'Laravel' "$page"

token="TurnKeyV19Persistence$$"
turnkey-artisan tinker --execute="Illuminate\\Support\\Facades\\Schema::dropIfExists('turnkey_acceptance'); Illuminate\\Support\\Facades\\Schema::create('turnkey_acceptance', function (Illuminate\\Database\\Schema\\Blueprint \$table) { \$table->id(); \$table->string('value'); }); Illuminate\\Support\\Facades\\DB::table('turnkey_acceptance')->insert(['value' => '$token']);"
MYSQL_PWD="$db_password" mariadb --user=root --batch --skip-column-names \
    laravel --execute 'SELECT value FROM turnkey_acceptance LIMIT 1' |
    grep -Fxq "$token"

turnkey-artisan make:job TurnKeyAcceptanceJob --quiet
sed -i "/public function handle()/,/^    }/c\\\
    public function handle(): void\\\
    {\\\
        file_put_contents('$queue_marker', 'queue-ok');\\\
    }" /var/www/laravel/app/Jobs/TurnKeyAcceptanceJob.php
turnkey-artisan tinker --execute="App\\Jobs\\TurnKeyAcceptanceJob::dispatch();"
turnkey-artisan queue:work database --once --no-interaction
grep -Fxq 'queue-ok' "$queue_marker"
rm -f /var/www/laravel/app/Jobs/TurnKeyAcceptanceJob.php
turnkey-artisan tinker --execute="Illuminate\\Support\\Facades\\Schema::drop('turnkey_acceptance');"

grep -Fxq '* * * * * root /usr/local/bin/turnkey-artisan schedule:run --no-interaction >/dev/null 2>&1' \
    /etc/cron.d/laravel
stat -c '%U:%G %a' /etc/cron.d/laravel | grep -Fxq 'root:root 644'
turnkey-artisan schedule:run --no-interaction >/dev/null

dpkg-query -W adminer webmin-apache webmin-mysql webmin-phpini postfix \
    >/dev/null
curl --insecure --fail --silent --show-error --head \
    https://127.0.0.1:12321/ >/dev/null
curl --insecure --fail --silent --show-error --head \
    https://127.0.0.1:12322/ >/dev/null
ss -ltn | grep -Eq '127\.0\.0\.1:25[[:space:]]'

before="$(dpkg-query -W -f='${Version}' php-cli)|$(dpkg-query -W -f='${Version}' mariadb-server)|$(dpkg-query -W -f='${Version}' composer)"
apt-get update >/dev/null
for package in php-cli mariadb-server composer; do
    apt-cache policy "$package" >"$policy"
    candidate=$(awk '/Candidate:/ {print $2}' "$policy")
    [[ -n $candidate && $candidate != '(none)' ]]
    grep -Eq 'trixie|deb13' "$policy"
done
after="$(dpkg-query -W -f='${Version}' php-cli)|$(dpkg-query -W -f='${Version}' mariadb-server)|$(dpkg-query -W -f='${Version}' composer)"
[[ $after == "$before" ]]
grep -Rqs '^Suites: trixie' /etc/apt/sources.list.d
! grep -Rqi bookworm /etc/apt/sources.list /etc/apt/sources.list.d

update_check=$(turnkey-composer --working-dir=/var/www/laravel \
    update --dry-run --no-interaction --no-dev 2>&1)
grep -Eq 'Nothing to modify in lock file|Lock file operations:' <<<"$update_check"

cat >"$result" <<EOF
package_source=Official Laravel application skeleton v13.10.0 at commit 9863f0544931b7e3062001a28e37f4fcf795ce5c; production dependencies resolved and locked by Composer during the build; PHP, MariaDB, Apache and Composer from Debian Trixie
installed_version=Laravel Framework $framework_version; $php_version; mariadb-server $(dpkg-query -W -f='${Version}' mariadb-server); composer $(dpkg-query -W -f='${Version}' composer)
runtime_checks=normal init; Apache and MariaDB supervision; HTTPS sample application; Artisan environment, route and migration commands; create-read-drop MariaDB persistence; database queue dispatch and worker execution; scheduler cron and invocation; Adminer, Webmin and local Postfix
updater_command=turnkey-composer update --dry-run --no-interaction --no-dev
updater_result=Composer resolved the supported Laravel 13 constraint and completed a non-mutating dependency update plan
updater_channel=https://packagist.org/packages/laravel/framework within the upstream skeleton constraint, with major upgrades following https://laravel.com/docs/upgrade
integrity_evidence=official skeleton tag and commit matched the build pin; Composer generated and validated the installed dependency lock and production platform requirements passed; APT accepted signed Trixie metadata; no Bookworm source remained
EOF
