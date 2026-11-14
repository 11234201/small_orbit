class IslandDecoration {
  const IslandDecoration(
    this.id,
    this.label,
    this.symbol,
    this.threshold,
    this.x,
    this.y,
  );
  final String id, label, symbol;
  final int threshold;
  final double x, y;
}

const islandDecorations = [
  IslandDecoration('sprout', '第一棵嫩芽', '🌱', 1, .25, .52),
  IslandDecoration('flower', '迎风小花', '🌼', 3, .40, .65),
  IslandDecoration('tree', '树荫', '🌳', 5, .70, .43),
  IslandDecoration('cottage', '小屋', '🏡', 10, .49, .40),
  IslandDecoration('tulip', '郁金香', '🌷', 20, .63, .66),
  IslandDecoration('pine', '松树', '🌲', 30, .19, .37),
  IslandDecoration('fountain', '小喷泉', '⛲', 40, .48, .75),
  IslandDecoration('sunflower', '向日葵', '🌻', 50, .79, .58),
  IslandDecoration('tent', '野营帐篷', '⛺', 60, .30, .72),
  IslandDecoration('windmill', '风车', '🏠', 70, .76, .28),
  IslandDecoration('blossom', '花树', '🌸', 80, .55, .25),
  IslandDecoration('castle', '星光小屋', '🏰', 90, .34, .23),
];
