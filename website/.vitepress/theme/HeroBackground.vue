<template>
  <div class="background" aria-hidden="true"></div>
</template>

<style scoped>
/* A faint dot field behind the hero. It frames the motto without competing with it. */
.background {
  position: absolute;
  z-index: -1;
  top: 0;
  left: 0;
  right: 0;
  height: 1100px;
  pointer-events: none;
  background-image: radial-gradient(var(--yuke-bg-mark) 1px, transparent 1.4px);
  background-size: 22px 22px;
  -webkit-mask-image: radial-gradient(ellipse 70% 60% at 50% 35%, #000 30%, transparent 100%);
  mask-image: radial-gradient(ellipse 70% 60% at 50% 35%, #000 30%, transparent 100%);
}
</style>
