import { h } from 'vue';
import DefaultTheme from 'vitepress/theme';
import HeroBackground from './HeroBackground.vue';
import HeroDemo from './HeroDemo.vue';
import HeroTitle from './HeroTitle.vue';
import HomeCta from './HomeCta.vue';
import HomeWhy from './HomeWhy.vue';
import SiteFooter from './SiteFooter.vue';
import '../../styles/yuke.css';

export default {
  extends: DefaultTheme,
  Layout: () => h(DefaultTheme.Layout, null, {
    'home-hero-before': () => h(HeroBackground),
    'home-hero-info': () => h(HeroTitle),
    'home-hero-after': () => h(HeroDemo),
    // VitePress has no slot after the home content; HomeCta moves itself last with `order`.
    'home-features-after': () => [h(HomeWhy), h(HomeCta)],
    'layout-bottom': () => h(SiteFooter),
  }),
};
