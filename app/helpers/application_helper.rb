module ApplicationHelper
  def formatHashrate(rate)
    rate = rate.to_f
    unit = 'H/s'

    if (rate >= 1000)
      rate /= 1000; unit = 'KH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'MH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'GH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'TH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'PH/s'
    end

    return (rate.round(2).to_s + ' ' + unit);
  end
end
