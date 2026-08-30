# homelab sterile test environment
#
# A throwaway Debian 13 VM that matches nucserver. Reset is a btrfs reflink
# copy of a pristine golden image: instant, and it costs zero extra disk.
#
#   make build   download the golden image (once, ~350 MB)
#   make up      boot a fresh VM and wait for SSH
#   make ssh     shell into it
#   make reset   throw it away and boot a pristine one
#   make down    shut it down
#   make status  what is running
#   make clean   remove all run state (keeps the golden image)

SHELL     := /bin/bash
.ONESHELL:

IMG_NAME  := debian-13-generic-amd64.qcow2
IMG_BASE  := https://cloud.debian.org/images/cloud/trixie/latest
GOLDEN    := golden/$(IMG_NAME)

RUN       := run
DISK      := $(RUN)/disk.qcow2
DATA      := $(RUN)/data.img
SEED      := $(RUN)/seed.img
KEY       := $(RUN)/id_ed25519
PID       := $(RUN)/qemu.pid
CONSOLE   := $(RUN)/console.log

# The VM is a small machine on purpose: if an app needs more than the NUC
# has (2 cores / 16 GB), we want to find that out here.
CPUS      := 2
MEM       := 4096
DATA_SIZE := 40G

SSH_PORT  := 2222
SSH_OPTS  := -i $(KEY) -p $(SSH_PORT) -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
             -o ConnectTimeout=5
VM        := eran@127.0.0.1

# Guest ports published to localhost. Add app ports here as apps are added.
HOSTFWD   := hostfwd=tcp::$(SSH_PORT)-:22,hostfwd=tcp::7070-:7070,hostfwd=tcp::8010-:8010,hostfwd=tcp::8096-:8096,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443

# SLIRP user-mode network. Deliberately 10.100.0.0/24 so it can never be
# confused with the real LAN at 10.0.0.0/24.
NETDEV    := user,id=n0,net=10.100.0.0/24,host=10.100.0.2,dns=10.100.0.3,$(HOSTFWD)

.PHONY: all build up down reset ssh status clean distclean check

# ---------------------------------------------------------------- preflight

check:
	set -e
	for c in qemu-system-x86_64 mkfs.vfat mcopy ssh-keygen curl; do
	  command -v $$c >/dev/null || { echo "missing: $$c"; exit 1; }
	done
	[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "no access to /dev/kvm"; exit 1; }
	echo probe > $(RUN)/.rl.src
	if cp --reflink=always $(RUN)/.rl.src $(RUN)/.rl.dst 2>/dev/null; then
	  echo "reflink: supported (resets are instant, zero extra disk)"
	else
	  echo "WARNING: $(CURDIR) is not on a reflink-capable fs (btrfs/xfs)."
	  echo "         Resets will do full copies instead of instant clones."
	fi
	rm -f $(RUN)/.rl.src $(RUN)/.rl.dst
	echo "preflight OK"

# ------------------------------------------------------------- golden image

build: $(GOLDEN)

$(GOLDEN):
	set -e
	mkdir -p golden
	echo "==> downloading $(IMG_NAME)"
	curl -fL --progress-bar -o golden/$(IMG_NAME).part $(IMG_BASE)/$(IMG_NAME)
	echo "==> verifying sha512"
	curl -fsSL $(IMG_BASE)/SHA512SUMS | grep " $(IMG_NAME)$$" \
	  | sed 's| .*| golden/$(IMG_NAME).part|' | sha512sum -c -
	mv golden/$(IMG_NAME).part $(GOLDEN)
	chmod 444 $(GOLDEN)
	echo "==> golden image ready: $(GOLDEN)"

# ------------------------------------------------------------------- ssh key

$(KEY):
	mkdir -p $(RUN)
	ssh-keygen -t ed25519 -N '' -C homelab-testenv -f $(KEY) >/dev/null
	echo "==> generated throwaway key $(KEY)"

# ---------------------------------------------------------------- boot media

$(DISK): $(GOLDEN)
	mkdir -p $(RUN)
	cp --reflink=auto $(GOLDEN) $(DISK)
	chmod 644 $(DISK)
	echo "==> root disk cloned (reflink)"

$(DATA):
	mkdir -p $(RUN)
	truncate -s $(DATA_SIZE) $(DATA)
	echo "==> data disk created, sparse $(DATA_SIZE)"

$(SEED): cloud-init/user-data.tpl cloud-init/meta-data $(KEY)
	set -e
	mkdir -p $(RUN)
	sed "s|@@SSH_PUBKEY@@|$$(cat $(KEY).pub)|" cloud-init/user-data.tpl > $(RUN)/user-data
	rm -f $(SEED)
	mkfs.vfat -n CIDATA -C $(SEED) 1024 >/dev/null
	mcopy -i $(SEED) $(RUN)/user-data ::user-data
	mcopy -i $(SEED) cloud-init/meta-data ::meta-data
	echo "==> cloud-init seed built"

# --------------------------------------------------------------------- boot

up: check $(DISK) $(DATA) $(SEED)
	set -e
	if [ -f $(PID) ] && kill -0 $$(cat $(PID)) 2>/dev/null; then
	  echo "already running (pid $$(cat $(PID)))"; exit 0
	fi
	echo "==> booting"
	qemu-system-x86_64 \
	  -name homelab-testenv \
	  -machine q35,accel=kvm -cpu host -smp $(CPUS) -m $(MEM) \
	  -drive if=virtio,file=$(DISK),format=qcow2 \
	  -drive if=virtio,file=$(DATA),format=raw \
	  -drive if=virtio,file=$(SEED),format=raw \
	  -netdev $(NETDEV) \
	  -device virtio-net-pci,netdev=n0 \
	  -display none -serial file:$(CONSOLE) \
	  -daemonize -pidfile $(PID)
	echo -n "==> waiting for ssh on :$(SSH_PORT) "
	for i in $$(seq 1 120); do
	  if ssh $(SSH_OPTS) -o BatchMode=yes $(VM) true 2>/dev/null; then
	    echo " ssh up"
	    # SSH answers well before cloud-init has installed packages and applied
	    # the firewall guard. Tests must not race provisioning, so block here.
	    echo -n "==> waiting for cloud-init "
	    ssh $(SSH_OPTS) $(VM) 'sudo cloud-init status --wait >/dev/null 2>&1' || true
	    st=$$(ssh $(SSH_OPTS) $(VM) 'sudo cloud-init status' 2>/dev/null)
	    echo "[$$st]"
	    case "$$st" in
	      *done*) echo "==> up and provisioned. 'make ssh' to enter."; exit 0 ;;
	      *) echo "cloud-init did not finish cleanly:"
	         ssh $(SSH_OPTS) $(VM) 'sudo cloud-init status --long' || true; exit 1 ;;
	    esac
	  fi
	  echo -n .; sleep 2
	done
	echo; echo "TIMED OUT. console tail:"; tail -40 $(CONSOLE); exit 1

ssh:
	ssh $(SSH_OPTS) $(VM)

down:
	if [ -f $(PID) ] && kill -0 $$(cat $(PID)) 2>/dev/null; then
	  ssh $(SSH_OPTS) -o BatchMode=yes $(VM) 'sudo poweroff' 2>/dev/null || true
	  for i in $$(seq 1 15); do kill -0 $$(cat $(PID)) 2>/dev/null || break; sleep 1; done
	  kill -0 $$(cat $(PID)) 2>/dev/null && kill $$(cat $(PID)) || true
	  echo "==> stopped"
	else
	  echo "==> not running"
	fi
	rm -f $(PID)

# Throw the machine away and boot a pristine one. This is the whole point.
reset:
	$(MAKE) --no-print-directory down
	rm -f $(DISK) $(DATA) $(CONSOLE)
	$(MAKE) --no-print-directory up

status:
	if [ -f $(PID) ] && kill -0 $$(cat $(PID)) 2>/dev/null; then
	  echo "vm:   running (pid $$(cat $(PID)))"
	else
	  echo "vm:   stopped"
	fi
	if ssh $(SSH_OPTS) -o BatchMode=yes $(VM) true 2>/dev/null; then
	  echo "ssh:  ok on port $(SSH_PORT)"
	  ssh $(SSH_OPTS) $(VM) 'echo "host: $$(hostname) / $$(. /etc/os-release; echo $$PRETTY_NAME)"; \
	    echo "disk: $$(df -h /var/lib/docker 2>/dev/null | tail -1 | tr -s " ")"; \
	    echo "mark: $$(cat /etc/homelab/allow-apply 2>/dev/null || echo MISSING)"'
	else
	  echo "ssh:  unreachable"
	fi

clean:
	$(MAKE) --no-print-directory down
	rm -rf $(RUN)
	echo "==> run state removed (golden image kept)"

distclean: clean
	rm -rf golden
	echo "==> golden image removed"
