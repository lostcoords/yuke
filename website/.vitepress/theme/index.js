import { h } from 'vue';
import DefaultTheme from 'vitepress/theme';
import Hero from './Hero.vue';
import Demo from './Demo.vue';
import Features from './Features.vue';
import MakeItYours from './MakeItYours.vue';
import SiteFooter from './SiteFooter.vue';
import '../../styles/yuke.css';

export default {
  extends: DefaultTheme,
  Layout: () => h(DefaultTheme.Layout, null, {
    'home-hero-before': () => h(Hero),
    'home-features-after': () => [h(Demo), h(Features), h(MakeItYours)],
    'layout-bottom': () => h(SiteFooter),
  }),
};
