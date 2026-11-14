enum GravityStyle { weightless, moon, jelly }

enum BubbleMaterial { classic, pudding, water, soap }

enum TaskEnergy { light, normal, demanding }

int stableSeed(String value) {
  var result = 2166136261;
  for (final unit in value.codeUnits) {
    result = ((result ^ unit) * 16777619) & 0x7fffffff;
  }
  return result;
}

const gravityLabels = ['失重', '月球', '果冻'];
const materialLabels = ['经典', '布丁', '水滴', '肥皂泡'];
const energyLabels = ['轻松', '普通', '费力'];
