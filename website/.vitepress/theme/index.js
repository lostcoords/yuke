import { h } from 'vue';
import DefaultTheme from 'vitepress/theme';
import Footprint from './Footprint.vue';
import Hero from './Hero.vue';
import HeroBackground from './HeroBackground.vue';
import HeroDemo from './HeroDemo.vue';
import HomeCta from './HomeCta.vue';
import HomeWhy from './HomeWhy.vue';
import SiteFooter from './SiteFooter.vue';
import '../../styles/yuke.css';

export default {
  extends: DefaultTheme,
  Layout: () => h(DefaultTheme.Layout, null, {
    // The frontmatter has no `hero`, so these slots draw the whole top of the page.
    'home-hero-before': () => [h(HeroBackground), h(Hero)],
    'home-hero-after': () => h(HeroDemo),
    // VitePress has no slot after the home content; HomeCta moves itself last with `order`.
    'home-features-after': () => [h(Footprint), h(HomeWhy), h(HomeCta)],
    'layout-bottom': () => h(SiteFooter),
  }),
};
