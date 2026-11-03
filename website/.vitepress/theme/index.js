import { h } from 'vue';
import DefaultTheme from 'vitepress/theme';
import Hero from './Hero.vue';
import Capabilities from './Capabilities.vue';
import SiteFooter from './SiteFooter.vue';
import '../../styles/yuke.css';

export default {
  extends: DefaultTheme,
  Layout: () => h(DefaultTheme.Layout, null, {
    'home-hero-before': () => h(Hero),
    'home-features-after': () => h(Capabilities),
    'layout-bottom': () => h(SiteFooter),
  }),
};
