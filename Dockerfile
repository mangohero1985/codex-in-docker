FROM ghcr.io/openai/codex-universal:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
  iptables \
  ipset \
  procps \
 && rm -rf /var/lib/apt/lists/*

ENV HOME=/home/dev
ENV RUNTIME_ROOT=/opt/codex-runtime
ENV XDG_CONFIG_HOME=/home/dev/.config
ENV NVM_DIR=/home/dev/.nvm
ENV PYENV_ROOT=/home/dev/.pyenv
ENV PHPENV_ROOT=/home/dev/.phpenv
ENV CARGO_HOME=/home/dev/.cargo
ENV RUSTUP_HOME=/home/dev/.rustup
ENV PIPX_BIN_DIR=/home/dev/.local/bin
ENV SWIFTLY_BIN_DIR=/home/dev/.swiftly/bin
ENV PATH=/home/dev/.cargo/bin:/home/dev/.phpenv/bin:/home/dev/.phpenv/shims:/usr/local/go/bin:/home/dev/go/bin:/home/dev/.swiftly/bin:/home/dev/.local/bin:/home/dev/.pyenv/bin:/home/dev/.pyenv/shims:/home/dev/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN mkdir -p /home/dev/workspace /home/dev/.codex /home/dev/.config "${RUNTIME_ROOT}" \
 && chmod -R 777 /home/dev \
 && git config --system --add safe.directory '*'

# codex-universal installs many runtimes under /root. Move them into a shared
# runtime directory, keep root-facing symlinks for compatibility, and expose
# user-facing symlinks under /home/dev so the non-root runtime no longer needs
# to traverse /root.
RUN if [ -d /root/.nvm ]; then mv /root/.nvm "${RUNTIME_ROOT}/nvm"; ln -s "${RUNTIME_ROOT}/nvm" /root/.nvm; fi \
 && if [ -d /root/.pyenv ]; then mv /root/.pyenv "${RUNTIME_ROOT}/pyenv"; ln -s "${RUNTIME_ROOT}/pyenv" /root/.pyenv; fi \
 && if [ -d /root/.cargo ]; then mv /root/.cargo "${RUNTIME_ROOT}/cargo"; ln -s "${RUNTIME_ROOT}/cargo" /root/.cargo; fi \
 && if [ -d /root/.rustup ]; then mv /root/.rustup "${RUNTIME_ROOT}/rustup"; ln -s "${RUNTIME_ROOT}/rustup" /root/.rustup; fi \
 && if [ -d /root/.swiftly ]; then mv /root/.swiftly "${RUNTIME_ROOT}/swiftly"; ln -s "${RUNTIME_ROOT}/swiftly" /root/.swiftly; fi \
 && if [ -d /root/.phpenv ]; then mv /root/.phpenv "${RUNTIME_ROOT}/phpenv"; ln -s "${RUNTIME_ROOT}/phpenv" /root/.phpenv; fi \
 && if [ -d /root/.local ]; then mv /root/.local "${RUNTIME_ROOT}/local"; ln -s "${RUNTIME_ROOT}/local" /root/.local; fi \
 && mkdir -p "${RUNTIME_ROOT}/config" /root/.config \
 && if [ -d /root/.config/mise ]; then mv /root/.config/mise "${RUNTIME_ROOT}/config/mise"; fi \
 && rm -rf /root/.config/mise \
 && ln -s "${RUNTIME_ROOT}/config/mise" /root/.config/mise \
 && if [ -d /root/go ]; then mv /root/go "${RUNTIME_ROOT}/go"; ln -s "${RUNTIME_ROOT}/go" /root/go; fi \
 && ln -sfn "${RUNTIME_ROOT}/nvm" /home/dev/.nvm \
 && ln -sfn "${RUNTIME_ROOT}/pyenv" /home/dev/.pyenv \
 && ln -sfn "${RUNTIME_ROOT}/cargo" /home/dev/.cargo \
 && ln -sfn "${RUNTIME_ROOT}/rustup" /home/dev/.rustup \
 && ln -sfn "${RUNTIME_ROOT}/swiftly" /home/dev/.swiftly \
 && ln -sfn "${RUNTIME_ROOT}/phpenv" /home/dev/.phpenv \
 && ln -sfn "${RUNTIME_ROOT}/local" /home/dev/.local \
 && mkdir -p /home/dev/.config \
 && ln -sfn "${RUNTIME_ROOT}/config/mise" /home/dev/.config/mise \
 && ln -sfn "${RUNTIME_ROOT}/go" /home/dev/go \
 && chmod -R a+rX "${RUNTIME_ROOT}" \
 && : > /etc/ld.so.conf.d/codex-runtime.conf \
 && if [ -d "${RUNTIME_ROOT}/pyenv/versions" ]; then \
      find "${RUNTIME_ROOT}/pyenv/versions" -mindepth 2 -maxdepth 2 -type d -name lib | sort >> /etc/ld.so.conf.d/codex-runtime.conf; \
    fi \
 && ldconfig \
 && bash -lc 'source /root/.nvm/nvm.sh && DEFAULT_NODE_BIN="$(dirname "$(nvm which default)")" && for tool in node npm npx corepack; do ln -sf "$DEFAULT_NODE_BIN/$tool" "/usr/local/bin/$tool"; done' \
 && npm install -g @openai/codex \
 && ln -sf "$(npm prefix -g)/bin/codex" /usr/local/bin/codex \
 && mv /usr/local/bin/codex /usr/local/bin/codex-real \
 && for tool in pnpm yarn bun cargo rustc rustup ruby gem bundle java javac gradle mvn elixir erl iex php composer; do \
      if [ -x "${RUNTIME_ROOT}/cargo/bin/$tool" ]; then ln -sf "${RUNTIME_ROOT}/cargo/bin/$tool" "/usr/local/bin/$tool"; fi; \
      if [ -x "${RUNTIME_ROOT}/phpenv/shims/$tool" ]; then ln -sf "${RUNTIME_ROOT}/phpenv/shims/$tool" "/usr/local/bin/$tool"; fi; \
      if [ -x "${RUNTIME_ROOT}/local/share/mise/shims/$tool" ]; then ln -sf "${RUNTIME_ROOT}/local/share/mise/shims/$tool" "/usr/local/bin/$tool"; fi; \
    done

COPY allowed-domains.txt /etc/codex-allowed-domains.txt
COPY codex-wrapper.sh /usr/local/bin/codex
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/codex /usr/local/bin/init-firewall.sh \
 && printf 'Defaults!/usr/local/bin/init-firewall.sh !pam_acct_mgmt\nALL ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\n' \
      > /etc/sudoers.d/codex-firewall \
 && chmod 0440 /etc/sudoers.d/codex-firewall

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /home/dev/workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
