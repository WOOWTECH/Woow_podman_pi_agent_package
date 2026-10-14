# Make interactive shells (`podman exec -it pi-web bash -l`) see the same
# environment as the pi-web server process.
# shellcheck source=/dev/null
[ -r /usr/local/bin/pi-agent-env.sh ] && . /usr/local/bin/pi-agent-env.sh
