# How `dr_mode=host` reaches the kernel — and why the early host scan fails

This document explains one mechanism that unifies every `linux usb` (initramfs)
boot in this investigation: **the bootloader unconditionally adds
`dr_mode=host` to the device tree in RAM before handing off to the kernel.**
That single property is what forces the kernel's DWC3 controller into HOST mode
from probe, so the **first host scan happens before the charger service is
ready**, and the pre-plugged drive is never enumerated.

It consolidates three questions:

1. How does ABL pass `dr_mode=host` to the kernel?
2. Can it be overridden from the kernel command line? (No.)
3. Why can ABL read the drive over USB without any problem, while the kernel
   needs a PDR gate?

Run-level evidence lives in
[FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md) and
[RESULTS.md](RESULTS.md). Line numbers refer to the `linux/` tree (v7.2.6).

---

## TL;DR

- In `linux usb` mode, ABL adds a `dr_mode = "host"` property to the **runtime
  device tree** (the FDT it hands to the kernel). The kernel's own DTB does not
  contain it. This is **verified** from `/proc/device-tree` dumps.
- `dr_mode` is a **device-tree property only**. It is **not** a kernel command
  line parameter and **not** a module parameter. Nothing on the command line can
  change it. (Verified in the kernel source.)
- The property forces `dwc3` into HOST mode at probe → `xhci-hcd` appears at
  ~0.5 s → the **first root-hub scan is at ~2.7 s**, which is **before** the
  `charger_pd` PDR indication at ~3.5 s. That early scan is absorbed (the ICM is
  still in standby waiting for the charger type), so the drive is not
  enumerated. **Fixing the timing turns out to be necessary but not sufficient**
  — with the demotion in place the port power path still never comes up
  (`usb_type=[Unknown]`, `online=0`), see the status block below.
- The full system (normal boot, **no** overlay) does not have this problem: it
  stays OTG, keeps the role switch, flips to HOST only **after** the PDR (on the
  UCSI partner event), and its first scan lands **2.7–4.4 s after** the PDR —
  and it enumerates the pre-plugged drive fine.
- The fix is therefore not a new driver. It is to make the kernel **not** honor
  the bootloader's static `dr_mode=host` when the device declares a
  `usb-role-switch`, so the kernel reproduces the full-system (known-good)
  behavior. That is **necessary but not sufficient**: it is implemented
  (PR #704 / patch 1400) and verified on device to fire, yet `linux usb`
  pre-plug still does not enumerate — the break is one step further down, on
  the port power path (status block below).

---

## What is verified (kernel source + `/proc/device-tree` dumps)

1. **The effect.** The runtime FDT seen by the kernel contains
   `dr_mode = "host"` in `linux usb` mode; the kernel's own DTB does not.
   Observed via the `[DT]` block that reads `/proc/device-tree` directly. The
   overlay is present in **both** DTB eras (spliced and unspliced). ABL does
   **not** remove `usb-role-switch` — its absence in the spliced era was our own
   DTB splice, not ABL.
2. **`dr_mode` is a DT property, not a kernel parameter.**
   `usb_get_dr_mode()` reads only the `dr_mode` device property
   (`drivers/usb/common/common.c:204-213`). There is **no** `module_param`,
   `__setup`, or `early_param` for `dr_mode` anywhere under `drivers/usb`
   (grep returns nothing). So the kernel command line has no hook for it.
3. **The DTB is passed to the kernel in `x0`.** Per the ARM64 boot protocol,
   `x0 = physical address of device tree blob (dtb) in system RAM`
   (`Documentation/arch/arm64/booting.rst:165`). Whatever is in the FDT at
   handoff is what the kernel sees.
4. **The kernel already has the full USB host stack.** `dwc3` + `xhci` +
   `usb-storage` are all built in. The initramfs failure is **not** a missing
   driver.
5. **Timing is the discriminator.** `linux usb` (initramfs): first scan ~2.7 s,
   PDR ~3.5 s → scan is *before* PDR → no enumeration. Full system: PDR 13.3 s,
   first scan 18.0 s → scan is *after* PDR → enumeration succeeds (`sdg` at
   ~20.5 s). See [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md).
6. **The role switch exists only on the OTG path.** `usb_role_switch_register()`
   in the dwc3 core is reached only when the controller is in dual-role/OTG mode
   with the `usb-role-switch` property (`drivers/usb/dwc3/drd.c`). In forced HOST
   mode the role-switch device is never created, which is also why `/sys/class/usb_role`
   is empty in every `linux usb` boot.

---

## How ABL passes `dr_mode=host` (inferred — ABL source is not available)

The *effect* (point 1 above) is verified. The *mechanism by which ABL produces
it* is **inferred**, because the ABL/XBL source is closed and not present in this
workspace. What is consistent with all the evidence:

- ABL **modifies the FDT in RAM before handoff** — either by setting the property
  directly (a `libfdt` `fdt_setprop_string()` call) or by applying a DTBO
  overlay that carries `dr_mode = "host"`. Which of the two is not locally
  verifiable.
- It then hands the modified FDT to the kernel via `x0` (ARM64 protocol, point 3).

The following is **illustrative pseudocode**, *not* quoted from a verified ABL
source. It is the shape the patch would have to take:

```c
/* Illustrative only — not from verified ABL source. */
static void patch_usb_for_boot(void *fdt)
{
    int node = fdt_path_offset(fdt, "/soc@0/usb@a600000");
    if (node >= 0)
        fdt_setprop_string(fdt, node, "dr_mode", "host");
}
/* ... then jump to the kernel with x0 = fdt ... */
```

The likely *intent* of the overlay: in `linux usb` mode the bootloader has just
acted as a USB **host** to read `KERNEL` from the stick, so it tells the kernel
"you were a host, keep being a host." That intent is exactly what backfires for
the pre-plug case (below).

> If you have access to the ABL source, the place to look is the code path that
> runs only in the USB-boot mode and touches the FDT: search for `dr_mode`,
> `fdt_setprop`, `fdt_overlay`, and the kernel-jump stub (the call that sets `x0`).

---

## Why ABL can read the drive, but the kernel's early scan fails

This is the crux, and it is **not** about a missing or special driver.

- **ABL ships its own, separate, closed USB host stack** (its own PHY/DWC3 bring-up
  plus its own mass-storage code) built into the bootloader. It is *not* the Linux
  `dwc3`/`xhci` driver. By the time ABL enumerates the stick, the USB-C/charger
  bring-up (done by the PPM/ADSP firmware plus the bootloader's own USB init) is
  already complete: the ICM is not in standby, the charger type has been
  delivered, and the data path is "hot." ABL enumerates an already-up link.
  (ABL internals are closed, so this last sentence is the supported inference,
  not a line-by-line verification.)

- **The kernel cannot reuse ABL's driver.** Different code base, it runs before
  the kernel, and the controller state is torn down and re-initialized at handoff.
  There is literally no way to "keep using ABL's USB stack."

- **What the kernel lacks is sequencing, not a driver.** On handoff the controller
  is re-initialized, and the ABL overlay `dr_mode=host` forces it straight into
  HOST mode. `xhci-hcd` is probed at ~0.5 s and the **first root-hub scan fires at
  ~2.7 s — before the `charger_pd` PDR indication at ~3.5 s**. That early scan
  lands while the ICM is still in standby waiting for the charger type, so it is
  absorbed and the drive is never enumerated.

- **The kernel can reproduce ABL's success condition without its code:** perform
  the **first host scan *after* the PDR** (when the charger type has been
  delivered and the ICM is out of standby). The full system already proves this
  works — its first scan is at 18 s, after the PDR at 13.3 s, and it enumerates
  the pre-plugged drive. That is precisely what the recommended fix does.
  **Caveat (2026-11-07):** the `dbg1400` run shows this condition is *not* the
  whole story — with the demotion active and the role flipped to HOST after the
  PDR, the drive still does not enumerate, because `qcom-battmgr-usb` stays
  `usb_type=[Unknown]` / `online=0` (the ICM `icm_ncp_stby` wedge) and no VBUS
  reaches the port. Timing gets the scan into the right window; the port still
  has to be classified. See [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md).

---

## Why the kernel command line cannot fix it

`dr_mode` is a **device-tree property**, not a kernel parameter (verified, point 2).
The kernel reads it via `device_property_read_string(dev, "dr_mode", ...)` in the
dwc3 driver; there is no module parameter, `__setup`, or `early_param` that would
let the command line override it.

Common command-line ideas and why each fails:

| Attempt | What it does | Why it doesn't help |
|---|---|---|
| `rootwait` / `rd.break` | Wait for / break to initramfs | The port is already "poisoned" by the pre-PDR first scan; waiting later doesn't un-poison it |
| `fw_devlink=permissive` | Change driver probe ordering | The problem is not probe order, it is the controller scanning before the charger service is ready |
| `xhci_hcd.quirks=...` | Toggle xHCI quirks | The problem is not in xHCI itself; it starts host mode too early |
| any `dr_mode=...` on the command line | — | There is no such parameter; the kernel only reads the DT property |

The only command-line-adjacent escape is `rd.break` to drop into the initramfs and
manually `unbind`/`bind` the controller **after** the PDR — which is just a manual,
non-automated version of the initramfs-script fix below.

---

## Fix options

| Option | Where | Feasible here | Notes |
|---|---|---|---|
| **Kernel patch (recommended)** | `dwc3`: demote `dr_mode=host` → OTG when `usb-role-switch` is present | Yes — needs a kernel (CI) build | Reproduces the full-system (known-good) behavior in the initramfs; also removes the UCSI deferral as a side effect (the role-switch device then exists) |
| ABL patch | ABL: only set `dr_mode=host` when `usb-role-switch` is **absent** | No — ABL is closed | The "right" place semantically, but not actionable |
| Initramfs script | dracut: hold the first scan until the PDR, then re-probe | Yes — no kernel rebuild | `unbind`/`bind` the **`xhci-hcd`** host device once the PDR line appears (not `dwc3-qcom` — UAF via UCSI); ships in the next CI image |

> **Status (2026-11-07, updated after the `dbg1400` run):** the kernel patch
> option was implemented as Armada PR #704 commit `a699dd6` (patch
> `1400-dwc3-ignore-dr-mode-host-with-role-switch.patch`, exactly the demotion
> above) and tested on device. First test: the CI image built from the branch
> carries the patch in the kernel (marker string verified in the flashed
> vmlinux) but `linux usb` pre-plug still ended in the dracut root-wait
> timeout — inconclusive at the time, because the image is `quiet` and carries
> no diagnostics. The follow-up `dbg1400` run closed that gap: **the demotion
> fired** (`dr_mode=host ignored: usb-role-switch present, using OTG` in
> dmesg), the runtime FDT carries both properties, the role-switch device is
> registered, ADSP is up and the role **flipped to HOST after the PDR** — and
> the drive *still* does not enumerate, because the **port power path stays
> dead** (`usb_type=[Unknown]`, `online=0`, ICM `icm_ncp_stby`, no VBUS).
> So 1400 is confirmed as a no-op-free, correctly-firing **partial** fix: it
> removes the early-scan ordering problem and leaves the classification
> problem (the same ICM `charger_type` wedge the initramfs has had all along).
> Remaining work, and the reconciliation with the measured replug window, are
> in [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md).

### Kernel patch (recommended)

The single choke point is `dwc3_get_dr_mode()` (`drivers/usb/dwc3/core.c:53`),
where `dwc->dr_mode` (set from the property at `core.c:1759`) is validated. Demote
a forced HOST to OTG whenever the device declares a role switch:

```c
static int dwc3_get_dr_mode(struct dwc3 *dwc)
{
	enum usb_dr_mode mode;
	struct device *dev = dwc->dev;
	unsigned int hw_mode;

	/*
	 * A static dr_mode=host (e.g. forced by the bootloader) contradicts a
	 * dynamic usb-role-switch. When the controller declares a role switch,
	 * the TYPE-C state machine must decide the role, not a fixed property.
	 * Demote to OTG so the role-switch/UCSI path can take over.
	 */
	if (dwc->dr_mode == USB_DR_MODE_HOST &&
	    device_property_read_bool(dev, "usb-role-switch")) {
		dev_warn(dev,
			 "dr_mode=host ignored: usb-role-switch present, using OTG\n");
		dwc->dr_mode = USB_DR_MODE_OTG;
	}

	if (dwc->dr_mode == USB_DR_MODE_UNKNOWN)
		dwc->dr_mode = USB_DR_MODE_OTG;

	mode = dwc->dr_mode;
	/* ... unchanged ... */
}
```

In a normal boot there is no `dr_mode` property, so `dwc->dr_mode` is already OTG
and this is a no-op. It only changes the `linux usb` (overlay) case, bringing it in
line with the full system. A secondary, cosmetic consideration: the `dwc3-qcom`
glue also reads `usb_get_dr_mode()` for its initial role
(`dwc3-qcom.c:686-698`); that value is only the starting role and is corrected by
the role-switch callback, so the core demotion above is the functional fix.

### Initramfs script (no kernel rebuild)

Final, implemented variant (2026-11-12) — full description and console verdicts
in [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md). Two corrections
against the sketch that used to be here:

1. **Rebind the `xhci-hcd` platform device, not `dwc3-qcom`.** Unbinding the
   glue driver unregisters the USB role-switch device that UCSI holds a
   reference to (`ucsi.c:1837`) and calls `set_role()` on at every connector
   change (`ucsi.c:1376,1958`) → use-after-free on the post-PDR attach. The
   xHCI host device is separate, keeps its quirk platform data across the
   unbind (`dwc3/host.c:199` → `xhci-plat.c:430`), and re-probing it gives
   exactly the fresh HCRST + root-hub scan we need.
2. **Gate on `dr_mode=host` in the live FDT**, not on "the PDR is already
   absent". In a *normal* boot the PDR arrives ~12 s from the real root, after
   `switch_root`; a hook that unbinds early and waits for a PDR would leave the
   controller down forever.

```sh
#!/bin/sh
# hold the first host scan until the charger_pd PDR, then re-probe
DT=/sys/bus/platform/devices/a600000.usb/of_node
DRV=/sys/bus/platform/drivers/xhci-hcd

[ "$(tr -d '\000' < "$DT/dr_mode" 2>/dev/null)" = host ] || exit 0   # linux usb only

N=
for d in "$DRV"/xhci-hcd.*; do [ -e "$d" ] && { N=${d##*/}; break; }; done
[ -n "$N" ] || exit 0
echo "$N" > "$DRV/unbind"

i=0
until dmesg | grep -q "PDR: Indication received from msm/adsp/charger_pd"; do
    i=$((i+1)); [ "$i" -ge 300 ] && break      # ~30 s bound, 0.1 s steps
    sleep 0.1
done

udevadm settle --timeout=10
echo "$N" > "$DRV/bind"
```

The shipped hook additionally: skips when a **USB-backed** `sd*` already exists,
verifies ≤10 s with up to 3 rebinds, stops on a new `Host halt failed, -110`,
and is idempotent across the repeated sourcing by `dracut-initqueue`.

---

## How to check on a running device

```sh
# See the runtime device tree as the kernel actually got it:
dtc -I fs -O dts /proc/device-tree | grep -A20 "usb@"
# Expect, in linux usb mode:  dr_mode = "host";  and  usb-role-switch;

# Confirm it is a DT property, not a command line:
cat /proc/cmdline   # no dr_mode= here

# The [DT] diagnostic block (dbg46 / dbg52) prints the same two properties.
```
