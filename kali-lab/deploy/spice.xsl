<?xml version="1.0" encoding="UTF-8"?>
<!--
  Full SPICE integration for a smooth desktop, applied to libvirt_domain via
  `xml { xslt = file("spice.xsl") }` (SPICE=true). Needs `xsltproc` on the host
  and `spice-vdagent` in the guest (DESKTOP bake). It:
    * ensures the video model is VIRTIO (virtio-gpu). IMPORTANT: dmacvicar emits
      NO <video> element, so libvirt otherwise injects its default *cirrus*
      (fixed ~1024 modes, no dynamic resize). We therefore ADD a <video> when
      none exists, and rewrite it to virtio if one does. virtio-gpu's driver is
      in-kernel (virtio_gpu), so it exposes arbitrary modes and spice-vdagent
      resizes the desktop to the window (VirtualBox-style), no guest package;
    * adds an ABSOLUTE pointing device (USB tablet) so the mouse is never
      "captured"/grabbed and crosses to the host seamlessly;
    * adds the SPICE vdagent virtio-serial channel (com.redhat.spice.0) that
      carries the shared clipboard and window-resize events.
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="xml" encoding="UTF-8" indent="yes"/>

  <!-- identity: copy everything unchanged by default -->
  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>

  <!-- if a <video><model> IS emitted, force it to virtio (drop cirrus attrs) -->
  <xsl:template match="/domain/devices/video/model">
    <model type="virtio" heads="1" primary="yes"/>
  </xsl:template>

  <!-- virtiofs needs the guest RAM backed by shared memory. Add it ONLY when a
       <filesystem> (a SHARE=) is present, so plain VMs are untouched. -->
  <xsl:template match="/domain">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
      <xsl:if test="devices/filesystem">
        <memoryBacking>
          <source type="memfd"/>
          <access mode="shared"/>
        </memoryBacking>
      </xsl:if>
    </xsl:copy>
  </xsl:template>

  <!-- dmacvicar emits the <filesystem> without a driver (defaults to 9p); inject
       <driver type='virtiofs'/> so the share uses the fast virtiofs transport. -->
  <xsl:template match="/domain/devices/filesystem">
    <xsl:copy>
      <xsl:apply-templates select="@*"/>
      <driver type="virtiofs"/>
      <xsl:apply-templates select="node()"/>
    </xsl:copy>
  </xsl:template>

  <!-- inside <devices>: add a virtio <video> when none exists (the usual case
       with dmacvicar), plus the SPICE channel and an absolute pointer -->
  <xsl:template match="/domain/devices">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
      <xsl:if test="not(video)">
        <video>
          <model type="virtio" heads="1" primary="yes"/>
        </video>
      </xsl:if>
      <channel type="spicevmc">
        <target type="virtio" name="com.redhat.spice.0"/>
      </channel>
      <input type="tablet" bus="usb"/>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
